# Availability Monitoring 
# 420-521-VA | Fall 2026

Our team will be using NetXMS to check if our Dell Precision 7680 and one of its network links are up. The scope of the project is to run NetXMS in a Docker container on a Debian VPS and use SNMP to check the laptop (Lenovo ThinkPad X13 Yoga Gen 4). For the demo, we’ll disconnect a secondary link and reconnect it so we can see the change on the dashboard.

# Team

- [Iulia Apintilioaie] - [2391115]
- [Sam Wilson]         - [2216511]
- [Matthew Pietracupa] - [2389418]

# How to Reproduce Our Setup

VPS address (Telnet): [100.75.133.39:2222]

1. Install [Docker and Compose on Debian].
2. Follow the [NetXMS Docker Compose setup] on the VPS. From the Compose folder, run `docker compose up -d` to start it and `docker compose ps` to check what’s running.
3. Enable an SNMP agent on the laptop. Make sure the VPS can reach it over a private connection, then add the laptop in NetXMS using its reachable IP address.
4. Use MIB Explorer to find the secondary adapter’s index. Poll `1.3.6.1.2.1.2.2.1.8.<index>` and add the result to the dashboard alongside the laptop’s status. [NetXMS SNMP setup]
5. Disconnect the secondary link, wait for the next poll, and check the dashboard. Reconnect it and check that it comes back up. Keep the main connection active so NetXMS can still reach the laptop.

# Repo folders

- `slides/` - presentation
- `src/` - scripts
- `config/` - configs with secrets removed
- `docs/report/` - final report
- `docs/plan/` - Lab 7 plan and Lab 9 PDF
- `evidence/` - screenshots and command output

# License

Planned license is MIT, it can be found under `LICENSE`.
