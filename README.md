# RabbitVCS with Cherry-pick on Ubuntu

RabbitVCS is the Linux version of TortoiseGit: it adds Git options to the right-click menu in the Files app.
Ubuntu's RabbitVCS has no cherry-pick option. The `rabbitvcs-cherry-pick.sh` script adds one, with abort on conflict.

---

## Step 1: Install RabbitVCS

```bash
sudo apt update
sudo apt install -y rabbitvcs-nautilus python3-nautilus
nautilus -q
```

> `SyntaxWarning` lines during the install are harmless. The install succeeded if you see `Setting up rabbitvcs-nautilus ...`.

Check it is installed:

```bash
dpkg -l | grep rabbitvcs
```

---

## Step 2: Install the cherry-pick option (one command, no manual download)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/RaviVishwakarma12/rabbitvcs/installer/rabbitvcs-cherry-pick.sh)"
```

> If `curl` is missing: `sudo apt install -y curl`

Expected output:

```
patching file rabbitvcs/ui/log.py
patching file rabbitvcs/util/contextmenuitems.py
Done. Open Show Log, right-click a commit, choose 'Cherry-pick this commit'.
```

Running it again is safe. It prints `Cherry-pick patch is already installed.`

---

## Step 3: Restart Files

```bash
nautilus -q
```

---

## Step 4: Verify

Both commands should print a line:

```bash
# Menu item added
grep -n "MenuCherryPick" /usr/lib/python3/dist-packages/rabbitvcs/util/contextmenuitems.py

# Abort-on-conflict added
grep -n 'cherry-pick", "--abort"' /usr/lib/python3/dist-packages/rabbitvcs/ui/log.py
```

---

## Step 5: Test on a throwaway repo

### 5.1 Create the test repo

```bash
rm -rf ~/cp-test && mkdir ~/cp-test && cd ~/cp-test
git init -q -b main
echo "line 1" > app.txt && git add . && git commit -qm "initial"

git checkout -qb feature
echo "new file" > extra.txt && git add . && git commit -qm "add extra.txt"
echo "more"     > more.txt  && git add . && git commit -qm "add more.txt"
echo "feature change" > app.txt && git commit -qam "change app.txt (feature)"

git checkout -q main
echo "main change" > app.txt && git commit -qam "change app.txt (main)"
```

### 5.2 Open the log window

From the terminal (errors, if any, show here):

```bash
cd ~/cp-test
rabbitvcs log .
```

Or: open `~/cp-test` in Files → right-click → **RabbitVCS Git → Show Log**.

### 5.3 Test cases

| # | Action | Expected |
|---|---|---|
| 1 | Right-click **add extra.txt** → **Cherry-pick this commit** → OK | "Cherry-pick completed", `extra.txt` appears |
| 2 | Right-click **add more.txt** → Cherry-pick → OK | Completes, `more.txt` appears |
| 3 | Right-click **change app.txt (feature)** → Cherry-pick → OK → conflict dialog → **OK** | Aborted, branch restored |
| 4 | Repeat 3, but click **Cancel** in the conflict dialog | Conflict kept for manual resolution |
| 5 | Right-click any commit → Cherry-pick → **Cancel** in the first dialog | Nothing happens |

Multi-select: Ctrl+click several commits, then right-click. They are applied oldest first.

### 5.4 Check results

```bash
git log --oneline -5   # new commits on main
git status             # test 3: clean; test 4: "both modified: app.txt"
```

After test 4, either abort:

```bash
git cherry-pick --abort
```

or resolve and continue:

```bash
# edit app.txt, then:
git add app.txt
git cherry-pick --continue
```

### 5.5 Clean up

```bash
rm -rf ~/cp-test
```

---

## Daily use

1. In Files, open your repo folder and right-click → **RabbitVCS Git → Show Log**.
2. The log shows commits from all branches. Select the commit(s) you want.
3. Right-click → **Cherry-pick this commit** → confirm the target branch → OK.
4. Push as usual.

---

## Remove the cherry-pick option only

Restores the original RabbitVCS files. RabbitVCS itself stays installed.

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/RaviVishwakarma12/rabbitvcs/installer/rabbitvcs-cherry-pick.sh)" _ --remove
```

---

## Fresh reinstall (everything from zero)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/RaviVishwakarma12/rabbitvcs/installer/rabbitvcs-cherry-pick.sh)" _ --remove
sudo apt purge -y rabbitvcs-nautilus rabbitvcs-core rabbitvcs-cli
sudo apt autoremove -y

sudo apt update
sudo apt install -y rabbitvcs-nautilus python3-nautilus
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/RaviVishwakarma12/rabbitvcs/installer/rabbitvcs-cherry-pick.sh)"
nautilus -q
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `curl: command not found` | `sudo apt install -y curl` |
| No RabbitVCS menu in Files | Run `nautilus -q` and reopen Files. Right-click inside a folder that is a Git repo. If it is still missing, check `nautilus --version`: RabbitVCS 0.19 may not load on Nautilus 46+. Use `rabbitvcs log .` from the terminal instead. |
| Menu present, but no Cherry-pick item | Re-run Step 4. If `grep` prints nothing, re-run Step 2. |
| RabbitVCS stops opening after the patch | `sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/RaviVishwakarma12/rabbitvcs/installer/rabbitvcs-cherry-pick.sh)" _ --remove`, then share the terminal output of `rabbitvcs log .` |
| Cherry-pick disappeared after `apt upgrade` | The package update overwrote the patch. Re-run Step 2. |

---

## Source

- Code: https://github.com/RaviVishwakarma12/rabbitvcs/tree/git-log-cherry-pick
- Once merged upstream and released, cherry-pick will come with the normal `apt install` and this script won't be needed.
