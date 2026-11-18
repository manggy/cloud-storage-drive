SELECT 'CREATE ROLE projectdrive_owner NOLOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'projectdrive_owner')
\gexec

SELECT format('CREATE ROLE %I NOLOGIN', name)
FROM (VALUES ('projectdrive_mac'), ('projectdrive_windows')) AS devices(name)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = name)
\gexec

GRANT projectdrive_owner TO projectdrive_mac, projectdrive_windows WITH SET TRUE;

SELECT 'CREATE DATABASE projectdrive OWNER projectdrive_owner'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'projectdrive')
\gexec

REVOKE ALL ON DATABASE projectdrive FROM PUBLIC;
GRANT CONNECT ON DATABASE projectdrive TO projectdrive_mac, projectdrive_windows;
-- Separate login identities share table ownership and can be revoked individually.
ALTER ROLE projectdrive_mac IN DATABASE projectdrive SET role TO projectdrive_owner;
ALTER ROLE projectdrive_windows IN DATABASE projectdrive SET role TO projectdrive_owner;
