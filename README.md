# ftploy

Incremental FTP deploy for any git repository. The command compares the commit already published (a `.deploy-info.json` marker on the server) with the local `HEAD` and uploads only what changed.

Linux dependencies: `bash`, `git`, `curl`, `python3`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/KaduAmaral/ftploy/main/install.sh | bash
```

```bash
wget -qO- https://raw.githubusercontent.com/KaduAmaral/ftploy/main/install.sh | bash
```

Either command installs or updates `ftploy`: running it again replaces the copy already installed. The examples below use `curl`; `wget -qO- URL` works in the same place.

The installer:

- downloads `deploy.sh` from this repository
- writes the `ftploy` command to `~/.local/bin/ftploy`
- if that directory is not on `PATH`, adds a marked block to `~/.bashrc`, `~/.zshrc`, or `config.fish`, matching the current shell

Open a new terminal and check:

```bash
ftploy --version
```

Install without changing the shell config:

```bash
curl -fsSL https://raw.githubusercontent.com/KaduAmaral/ftploy/main/install.sh | bash -s -- --no-modify-path
```

Install into another directory:

```bash
curl -fsSL https://raw.githubusercontent.com/KaduAmaral/ftploy/main/install.sh | bash -s -- --dir "$HOME/bin"
```

The default install is for the current user. A root shell would write to `/root/.local/bin`. For a system-wide command:

```bash
curl -fsSL https://raw.githubusercontent.com/KaduAmaral/ftploy/main/install.sh | sudo bash -s -- --dir /usr/local/bin --no-modify-path
```

To pin a version, the tag in the URL and `--ref` must be the same name:

```bash
curl -fsSL https://raw.githubusercontent.com/KaduAmaral/ftploy/v0.1.0/install.sh | bash -s -- --ref v0.1.0
```

## Uninstall

```bash
ftploy --uninstall
```

This removes the installed command and the `# >>> ftploy >>>` block from the shell config files. If `ftploy` is not on `PATH`:

```bash
curl -fsSL https://raw.githubusercontent.com/KaduAmaral/ftploy/main/install.sh | bash -s -- --uninstall
```

```bash
wget -qO- https://raw.githubusercontent.com/KaduAmaral/ftploy/main/install.sh | bash -s -- --uninstall
```

## Use in a project

From the project directory, run `ftploy`. If `.env.deploy` is missing there and at the git root, the command asks for host, user, password, remote directory, port, and FTPS, then writes the file in the current directory with mode `600`. See `.env.deploy.example` for the keys.

```bash
cd /path/to/project
ftploy
ftploy --full
ftploy --env /path/to/.env.deploy --root /path/to/project
```

`.env.deploy` belongs to the project being published. Keep the password out of git.

## What the installer runs

Read [`install.sh`](install.sh) before running it. It only writes the command into the chosen directory and, when needed, a `PATH` block in your shell rc file.
