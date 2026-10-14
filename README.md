![Two luminous agents sharing a development workspace](assets/readme-banner.png)

# Agent Devstation

A prebuilt Docker workspace for **Codex**, **Claude Code**, GitHub CLI, and optional SDKs, Docker client tools, Playwright Chromium, and browser editing. Projects live under `/home/dev/workspaces`; the agents and editor share the same files and SDKs. Images support Linux AMD64 and ARM64. Neither setup needs a repository clone or image build.

Set `AGENT_DEVSTATION_DOCKER_CLI_ENABLED=true` to install Docker CLI, Compose, and Buildx at startup, then [connect to a development Docker daemon](docs/guide.md#docker-client-tools). Set `AGENT_DEVSTATION_PLAYWRIGHT_CHROMIUM_ENABLED=true` to [install a shared Chromium browser](docs/guide.md#playwright-chromium); each project supplies its own Playwright package. Both options are off by default and download only when selected.

## Simple setup: terminal agents

Use this for terminal work without changing host sandbox settings. Codex runs with full access **inside the container**; its phone Remote Control is unavailable in this setup.

1. Install Docker Engine with Compose. Copy [compose.yaml](compose.yaml) into a folder on your server and run `docker compose up -d`. The file pulls the prebuilt image and creates `workspaces/` beside it.
2. Sign in to the agent you want to use:

   ```sh
   docker compose exec -u dev agent-devstation codex login --device-auth
   docker compose exec -u dev agent-devstation claude auth login
   ```

3. Clone a project, then run either agent from it:

   ```sh
   docker compose exec -u dev agent-devstation git clone https://github.com/you/project.git /home/dev/workspaces/project
   docker compose exec -u dev -w /home/dev/workspaces/project agent-devstation codex --no-daemon --sandbox danger-full-access
   docker compose exec -u dev -w /home/dev/workspaces/project agent-devstation claude
   ```

Run `docker compose exec -u dev agent-devstation bash` for a shell. The default Compose selects Python `3.14` and Node.js `24`; [change SDKs or enable the editor](#customize-either-setup) when needed. Claude Code phone Remote Control is also available with an eligible subscription; see the [full setup](#full-setup-editor-and-phone-remote-control).

## Full setup: editor and phone Remote Control

This enables the browser editor and Codex's Linux sandbox so you can use **either or both agents' official phone workflows**. Codex phone pairing in a headless container is experimental and depends on your ChatGPT account and phone UI. Claude Code requires an eligible subscription account; an API key alone cannot enable its Remote Control.

1. Install Docker Engine with Compose. Save this complete example as `compose.yaml` in a folder on your server. Choose SDK versions you need; empty values leave those SDKs off.

   ```yaml
   services:
     agent-devstation:
       image: ghcr.io/lucurlings/agent-devstation:latest
       hostname: agent-devspace
       container_name: agent-devspace
       pull_policy: always
       restart: unless-stopped
       init: true
       security_opt:
         - seccomp=unconfined
         - apparmor=unconfined
       environment:
         AGENT_DEVSTATION_SDK_PYTHON: "3.14"
         AGENT_DEVSTATION_SDK_NODE: "24"
         AGENT_DEVSTATION_SDK_DOTNET: ""
         AGENT_DEVSTATION_SDK_JAVA: ""
         AGENT_DEVSTATION_SDK_GO: ""
         AGENT_DEVSTATION_SDK_RUST: ""
         AGENT_DEVSTATION_VSCODE_EDITOR_ENABLED: "true"
         AGENT_DEVSTATION_VSCODE_PASSWORD: ${AGENT_DEVSTATION_VSCODE_PASSWORD:?Set it in .env}
         AGENT_DEVSTATION_UID: "1000"
         AGENT_DEVSTATION_GID: "1000"
       volumes:
         - ./workspaces:/home/dev/workspaces
         - devstation-home:/home/dev
       ports:
         - "127.0.0.1:8080:8080"

   volumes:
     devstation-home:
   ```

2. In the same folder, create a local `.env` containing `AGENT_DEVSTATION_VSCODE_PASSWORD=your-long-unique-password`, replacing the example value with a unique password. Keep it private and out of Git. Run `docker compose up -d`; first startup downloads the selected SDKs and editor. The password opens the editor's own login page; it is separate from agent accounts.
3. Sign in to **one or both** agents, then add a project. Codex phone control needs ChatGPT sign-in; Claude phone control needs an eligible subscription sign-in.

   ```sh
   docker compose exec -u dev agent-devstation codex login --device-auth
   docker compose exec -u dev agent-devstation claude auth login
   docker compose exec -u dev agent-devstation git clone https://github.com/you/project.git /home/dev/workspaces/project
   ```

   Run only the login commands you need. If you use GitHub CLI, also run `docker compose exec -u dev agent-devstation gh auth login`.

4. If you want Codex phone control, check its sandbox:

   ```sh
   docker compose exec -u dev agent-devstation codex sandbox -c 'sandbox_mode="read-only"' /bin/sh -lc 'cd "$HOME" && pwd -P'
   ```

   It should print `/home/dev`. For `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`, follow the [Ubuntu 24.04 or 26.04 host instructions](docs/guide.md#bwrap-loopback-error). The image includes `bubblewrap`; the two `security_opt` settings relax Docker's seccomp and container AppArmor filters for this service.

5. Run the phone commands for whichever agent you use. Codex starts its background server and pairs while signed in to the same ChatGPT account. Claude Code shows a URL or QR code; keep its command running while using it.

   ```sh
   docker compose exec -u dev agent-devstation codex remote-control start
   docker compose exec -u dev agent-devstation codex remote-control pair
   docker compose exec -u dev -w /home/dev/workspaces/project agent-devstation claude remote-control
   ```

   Codex resumes a successful Remote Control start after container recreation; Claude's command must be run again. Neither agent needs a public inbound port. [Phone details and limitations](docs/guide.md#official-phone-remote-control).

6. Open the editor at `http://localhost:8080` **on the Docker host** and enter the `.env` password. From another machine, run `ssh -L 8080:127.0.0.1:8080 user@your-server` and open `http://localhost:8080` locally. Alternatively, use your own reverse proxy with TLS, authentication, and WebSocket support. A containerized proxy must share a Docker network with Agent Devstation and target **port 8080**. Only the editor uses that port; do not publish an agent protocol port. [Editor details](docs/guide.md#browser-editor).

   You can also run Remote Control from the browser VS Code terminal. Open **Terminal → New Terminal**; it already runs inside Agent Devstation as `dev` and shares the saved agent logins. Change to your project directory, then run the commands directly for whichever agent you use:

   ```sh
   cd /home/dev/workspaces/project

   # Codex
   codex remote-control start
   codex remote-control pair

   # Claude Code
   claude remote-control
   ```

   Replace `project` with your project folder. Keep the Claude Code Remote Control terminal running while using it.

Use `docker compose exec -u dev -w /home/dev/workspaces/project agent-devstation codex` or the equivalent `claude` command for normal terminal sessions. You can move from the simple setup to this one without losing projects or logins if you keep the same mounts and volume name.

## Customize either setup

| Compose variable | Example |
| --- | --- |
| `AGENT_DEVSTATION_SDK_PYTHON` | `3.14` |
| `AGENT_DEVSTATION_SDK_NODE` | `24` |
| `AGENT_DEVSTATION_SDK_DOTNET` | `10` |
| `AGENT_DEVSTATION_SDK_JAVA` | `21` |
| `AGENT_DEVSTATION_SDK_GO` | `1.26` |
| `AGENT_DEVSTATION_SDK_RUST` | `1.85` |

Set versions in Compose (or use an ignored `.env` with the linked default Compose file). An empty value disables an SDK. A partial number selects the latest matching release at install time; an exact number such as `24.0.1` pins it. `.x` is not accepted. After editing Compose, run `docker compose up -d`: Compose recreates the container and startup installs selected SDKs and removes unselected ones. A normal restart reuses installed versions. [SDK details](docs/guide.md#sdk-selection).

Optional tools use `AGENT_DEVSTATION_DOCKER_CLI_ENABLED=true` and `AGENT_DEVSTATION_PLAYWRIGHT_CHROMIUM_ENABLED=true`. Both default to false. Set `AGENT_DEVSTATION_PLAYWRIGHT_VERSION` to the exact Playwright version used by your project; its default is `1.63.0`.

The linked Compose file leaves the editor off. To enable it there, set `AGENT_DEVSTATION_VSCODE_EDITOR_ENABLED=true`, set `AGENT_DEVSTATION_VSCODE_PASSWORD` in `.env`, and uncomment its loopback port mapping. Disabling it removes its installation. On Linux, set `AGENT_DEVSTATION_UID` and `AGENT_DEVSTATION_GID` to match your project files if they are not owned by `1000:1000`.

[Codex and Claude API-key login](docs/guide.md#authentication) is available for terminal use. Codex phone pairing requires ChatGPT sign-in; Claude phone control requires subscription sign-in. Credentials live in the home volume, never in the image.

## Updates and security

`latest` follows full releases; `nightly` follows successful merges to `main`. Run `docker compose up -d` to pull updates, and replace your copied Compose file when its settings change. Back up both `workspaces/` and the named home volume; `docker compose down -v` deletes the home volume. Do not mount the Docker socket or expose the editor without authentication. [Troubleshooting](docs/guide.md#updates-troubleshooting-and-security).

Original project code is [Apache 2.0 licensed](LICENSE). See [Contributing](CONTRIBUTING.md), [Security](SECURITY.md), the [Code of Conduct](CODE_OF_CONDUCT.md), and [repository settings](docs/repository-settings.md).

<a href="https://www.star-history.com/?repos=LucUrlings%2Fagent-devstation&type=date"><img alt="Agent Devstation star history" src="https://api.star-history.com/chart?repos=LucUrlings/agent-devstation&type=date" /></a>
