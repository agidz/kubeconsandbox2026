#!/usr/bin/env python3
"""Verify pinned Hugging Face files and build an OCI image layout.

Usage: model_oci.py REPO REVISION WORK_DIR TAG
Keep the verified cache in WORK_DIR/files and emit a read-only weights layer
under WORK_DIR/layout. The Hub supplies LFS SHA-256 and Git blob identifiers.
"""
import hashlib, json, os, shutil, sys, tarfile, urllib.request

HUB = os.environ.get("HF_ENDPOINT", "https://huggingface.co")
SKIP = {".gitattributes", "README.md"}
CHUNK = 8 << 20


def get_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": "kubeconsandbox-model-push"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def file_hash(path, algorithm, prefix=b""):
    digest = hashlib.new(algorithm, prefix)
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def verified(path, entry):
    try:
        if os.stat(path).st_size != entry["size"]:
            return False
    except FileNotFoundError:
        return False
    lfs = entry.get("lfs")
    if lfs:
        return file_hash(path, "sha256") == lfs["oid"]
    git_header = f"blob {entry['size']}\0".encode()
    return file_hash(path, "sha1", git_header) == entry["oid"]


def download(repo, revision, entry, destination):
    path = entry["path"]
    request = urllib.request.Request(
        f"{HUB}/{repo}/resolve/{revision}/{path}",
        headers={"User-Agent": "kubeconsandbox-model-push"},
    )
    partial = destination + ".part"
    count = 0
    last_bucket = -1
    with urllib.request.urlopen(request, timeout=120) as response, open(partial, "wb") as target:
        for block in iter(lambda: response.read(CHUNK), b""):
            count += target.write(block)
            progress = count * 100 // max(entry["size"], 1)
            bucket = progress // 10
            if entry["size"] > (100 << 20) and bucket != last_bucket:
                print(f"      {path}: {progress}%", flush=True)
                last_bucket = bucket
    os.replace(partial, destination)


def blob(layout, data=None, path=None):
    """Write bytes (or move a file) into blobs/sha256/<digest>; return (digest, size)."""
    if path:
        digest = file_hash(path, "sha256")
        size = os.path.getsize(path)
        os.replace(path, os.path.join(layout, "blobs", "sha256", digest))
    else:
        digest = hashlib.sha256(data).hexdigest()
        size = len(data)
        with open(os.path.join(layout, "blobs", "sha256", digest), "wb") as f:
            f.write(data)
    return f"sha256:{digest}", size


def main(repo, rev, work, tag):
    files, layout = os.path.join(work, "files"), os.path.join(work, "layout")
    os.makedirs(files, exist_ok=True)
    tree = [e for e in get_json(f"{HUB}/api/models/{repo}/tree/{rev}") if e["type"] == "file" and e["path"] not in SKIP]
    if any("/" in e["path"] for e in tree):
        sys.exit("nested model files aren't supported yet")
    for e in tree:
        dest = os.path.join(files, e["path"])
        if verified(dest, e):
            continue
        print(f"    downloading {e['path']} ({e['size'] / 1e6:.0f} MB)", flush=True)
        download(repo, rev, e, dest)
        if not verified(dest, e):
            sys.exit(f"{e['path']}: hash mismatch against the Hub's tree for {rev}")
    print(f"    {len(tree)} files verified against the Hub ({repo}@{rev[:12]})", flush=True)

    shutil.rmtree(layout, ignore_errors=True)   # always rebuilt from the verified files
    os.makedirs(os.path.join(layout, "blobs", "sha256"), exist_ok=True)
    layer_tmp = os.path.join(layout, "layer.tar")
    with tarfile.open(layer_tmp, "w", format=tarfile.PAX_FORMAT) as t:   # reproducible: fixed order, owner, mtime
        for e in sorted(tree, key=lambda e: e["path"]):
            info = t.gettarinfo(os.path.join(files, e["path"]), arcname=e["path"])
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            info.mode = 0o444
            with open(os.path.join(files, e["path"]), "rb") as f:
                t.addfile(info, f)
    layer_digest, layer_size = blob(layout, path=layer_tmp)
    src = f"{HUB}/{repo}"
    config = {"architecture": "amd64", "os": "linux", "config": {},
              "rootfs": {"type": "layers", "diff_ids": [layer_digest]},
              "history": [{"created_by": f"kubeconsandbox model_oci.py: {repo}@{rev}"}]}
    cfg_digest, cfg_size = blob(layout, json.dumps(config, sort_keys=True).encode())
    annotations = {"org.opencontainers.image.source": src, "org.opencontainers.image.revision": rev,
                   "org.opencontainers.image.title": repo, "org.opencontainers.image.description": "model weights"}
    manifest = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": cfg_digest, "size": cfg_size},
                "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": layer_digest, "size": layer_size}],
                "annotations": annotations}
    man_digest, man_size = blob(layout, json.dumps(manifest, sort_keys=True).encode())
    with open(os.path.join(layout, "oci-layout"), "w") as f:
        json.dump({"imageLayoutVersion": "1.0.0"}, f)
    with open(os.path.join(layout, "index.json"), "w") as f:
        json.dump({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json",
                   "digest": man_digest, "size": man_size,
                   "annotations": {"org.opencontainers.image.ref.name": tag}}]}, f)
    print(f"    OCI layout ready: {layout}:{tag} (layer {layer_size / 1e9:.2f} GB, manifest {man_digest[:19]})", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
