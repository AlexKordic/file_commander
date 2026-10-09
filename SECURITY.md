# Security reports

FC is a public open-source project at the release-candidate stage. There is no
supported stable binary release series or guaranteed security-response timeline.

Report vulnerabilities privately through GitHub's **Report a vulnerability**
entry on the repository Security tab when available. If private reporting is not
enabled, contact the owner through the contact details published on their
[GitHub profile](https://github.com/AlexKordic). Do not post exploit details or
credentials in a public issue while arranging a private report.

Include the FC revision, OS/architecture, dependency revisions, affected
operation, a minimal reproduction and the observed impact. Remove credentials,
hostnames and personal paths from attached logs where appropriate.

FC inherits OpenSSH's host configuration and authentication. Remote operations
run with the SSH account's permissions; the remote helper is not a privilege
boundary. Lua scripts, Fresh plugins and editor commands execute code with the
user's permissions. Archive extraction, checkpoint recovery and cross-host
transfers are particularly relevant areas for security reports.
