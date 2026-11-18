# ADR-003 — Project governance and software licenses

**Status** Accepted on 2026-11-14

Recipients should be able to run the complete demo without trials, paid capabilities, or enterprise-license keys. Neutral governance is preferred so the project can be handed off independently of any one vendor.

Select free and open-source components. Prefer CNCF graduated projects, then incubating projects, then sandbox projects. Other Linux Foundation projects qualify, including OpenBao under OpenSSF and vLLM under the PyTorch Foundation. For a component outside those foundations, record why a qualifying option fails to meet the requirements. Gitea and Grafana OSS have dedicated decisions.

Record governance and licensing for each selected component. Evaluate software shipped as part of an upstream stack with that upstream. A tool chosen solely for immediate functionality can add licensing and handoff dependencies that the sandbox is designed to avoid.
