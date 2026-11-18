-- Modified for CloudNativePG post-init. Apache-2.0. See THIRD_PARTY_NOTICES.md.
-- PostgreSQL roles adapted from upstream kagent-setup.sql for CNPG post-init.
-- Certificate authentication uses the login roles without stored passwords.
DO $provision$
DECLARE
    app_schema CONSTANT text := 'kagent';
    schema_role CONSTANT text := 'kagent_owner';
    rw_role CONSTANT text := 'kagent_readwrite';
    login_owner CONSTANT text := 'kagent_owner_user';
    login_rw CONSTANT text := 'kagent_readwrite_user';
    entry record;
    existing record;
    actual_owner text;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('kagent:setup:' || app_schema, 0));

    FOR entry IN
        SELECT * FROM (VALUES
            (schema_role, false), (rw_role, false), (login_owner, true), (login_rw, true)
        ) AS requested(role_name, login_enabled)
    LOOP
        SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolinherit
        INTO existing
        FROM pg_roles
        WHERE rolname = entry.role_name;

        IF NOT FOUND THEN
            EXECUTE format(
                'CREATE ROLE %I %s NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION',
                entry.role_name,
                CASE WHEN entry.login_enabled THEN 'LOGIN NOINHERIT' ELSE 'NOLOGIN' END
            );
        ELSIF existing.rolcanlogin <> entry.login_enabled
            OR existing.rolsuper OR existing.rolcreatedb OR existing.rolcreaterole
            OR existing.rolreplication OR (entry.login_enabled AND existing.rolinherit)
        THEN
            RAISE EXCEPTION 'Role "%" has incompatible attributes', entry.role_name;
        END IF;

        IF entry.login_enabled THEN
            EXECUTE format('ALTER ROLE %I PASSWORD NULL', entry.role_name);
        END IF;
    END LOOP;

    EXECUTE format('GRANT %I TO %I', schema_role, login_owner);
    EXECUTE format('GRANT %I TO %I', rw_role, login_rw);

    SELECT pg_get_userbyid(nspowner)
    INTO actual_owner
    FROM pg_namespace
    WHERE nspname = app_schema;

    IF NOT FOUND THEN
        EXECUTE format('CREATE SCHEMA %I AUTHORIZATION %I', app_schema, schema_role);
    ELSIF actual_owner <> schema_role THEN
        RAISE EXCEPTION 'Schema "%" belongs to "%", expected "%"', app_schema, actual_owner, schema_role;
    END IF;

    REVOKE CREATE ON SCHEMA public FROM PUBLIC;
    EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', app_schema);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', app_schema, rw_role);
    EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
        schema_role, app_schema, rw_role
    );
    EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I',
        schema_role, app_schema, rw_role
    );
    EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT EXECUTE ON ROUTINES TO %I',
        schema_role, app_schema, rw_role
    );
    EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT USAGE ON TYPES TO %I',
        schema_role, app_schema, rw_role
    );
END
$provision$;
