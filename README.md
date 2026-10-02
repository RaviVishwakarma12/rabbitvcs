# RabbitVCS with TortoiseGit-style Cherry Pick on Ubuntu

RabbitVCS is the Linux version of TortoiseGit: it adds Git options to the right-click menu in the Files app.
Ubuntu's RabbitVCS has no cherry-pick. The `rabbitvcs-cherry-pick.sh` script adds TortoiseGit's cherry-pick, ported from TortoiseGit's own source code (its log dialog and its Rebase/Cherry Pick dialog).

## What you get

**Show Log window**

| Feature | Same as TortoiseGit |
|---|---|
| The log opens on your **current branch** | Yes |
| **Branch name at the top left**: click it to open **Browse References** (local branches, remote branches, tags, with a filter) | Yes |
| Right-click the branch name: **Browse references**, **HEAD -> "branch"**, **FETCH_HEAD**, **All**, **All basic refs**, **All local branches**, and recently chosen branches | Yes |
| **All Branches** check box at the bottom left | Yes |
| Right-click commits: **Cherry Pick this commit...** / **Cherry Pick selected commits...** (hidden on the HEAD commit and while a merge or cherry-pick is in progress) | Yes |

**Cherry Pick window**

| Feature | Same as TortoiseGit |
|---|---|
| Commit list with **REBASE / ID / SHA-1 / Message / Author / Date**, applied from the bottom up | Yes |
| Per commit: **Pick**, **Squash (with commit below)**, **Edit**, **Skip** (right-click, or keys `P`, `Q`, `E`, `S`, `Space` to cycle) | Yes |
| **Pick ALL** button with **Squash ALL**, **Edit ALL**, **Skip unselected**, **Squash unselected**, **Edit unselected** | Yes |
| **Up** / **Down** (Shift: to the top / bottom), **Add** more commits | Yes |
| **add "cherry picked from"** (remembered) | Yes |
| Tabs: **Revision Files**, **Commit Message**, **Log**; progress bar with **Rebasing... (n/m)** | Yes |
| One main button: **Continue** → **Commit** (after a conflict) / **Amend** (Edit) / **Commit** (Squash) → **Done** | Yes |
| Uncommitted changes: *"The current working tree is not clean. Do you want to stash the changes?"*, and at the end *"Do you want to stash pop now?"* | Yes |
| Merge commits: choose **Parent 1** or **Parent 2** | Yes |
| Commit becomes empty: **Commit** / **Skip** / **Cancel** | Yes |
| Pick fails without a conflict: **Skip** / **Retry** / **Cancel**, plus **Do the same for the rest** | Yes |
| **Conflict Files** tab with check boxes; right-click: **Edit conflicts** (3-way merge in Meld), **Resolved**, **Resolve conflict using "CHERRY_PICK_HEAD (…)"**, **Resolve conflict using "HEAD"** | Yes |
| **Delete/modify merge conflict** dialog: **Modified** / **Delete** / **Abort** | Yes |
| Warning if the message still contains `# Conflicts:` lines: **Ignore** / **Abort** | Yes |
| **Abort**: *"Are you sure you want to abort the rebase process?"* → branch goes back to where it was (also after Done) | Yes |

---

## Step 1: Install RabbitVCS and Meld

```bash
sudo apt update
sudo apt install -y rabbitvcs-nautilus python3-nautilus meld curl
```

`meld` is the 3-way merge tool that **Edit conflicts** opens.

> `SyntaxWarning` lines during the install are harmless.

---

## Step 2: Add cherry-pick (also upgrades older versions)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/RaviVishwakarma12/rabbitvcs/installer/rabbitvcs-cherry-pick.sh)"
```

The last line should be:

```
Done. Open Show Log, click the branch name at the top left to pick a branch, right-click a commit, choose 'Cherry Pick this commit...'.
```

Running it again prints `Cherry-pick patch is already installed and up to date.`

---

## Step 3: Restart Files

```bash
nautilus -q
```

---

## Step 4: Verify the install

```bash
cat /usr/lib/python3/dist-packages/rabbitvcs/.cherry-pick-patch
ls /usr/lib/python3/dist-packages/rabbitvcs/ui/cherrypick.py /usr/lib/python3/dist-packages/rabbitvcs/ui/refbrowser.py
```

Expected: the version code `18f0ad6d9523` and both file paths.

---

## Step 5: Test on a throwaway repo

### 5.1 Create the test repo

```bash
rm -rf ~/cp-test && mkdir ~/cp-test && cd ~/cp-test
git init -q -b main
printf 'line 1\nline 2\nline 3\n' > app.txt && git add . && git commit -qm "initial"

git checkout -qb volza-bugfix-ejs-node
echo fix1 > fix1.txt && git add . && git commit -qm "Volza 74674: fix live errors"
echo fix2 > fix2.txt && git add . && git commit -qm "Volza 74674: fix search API"
printf 'line 1\nline 2 from bugfix\nline 3\n' > app.txt && git commit -qam "Volza 74674: app change"

git checkout -q main && git checkout -qb ravi/task/new-update
printf 'line 1\nline 2 from my task\nline 3\n' > app.txt && git commit -qam "my task work"
echo wip > notes.txt && git add notes.txt && git commit -qm "notes"
echo uncommitted >> notes.txt
```

The last line leaves an uncommitted change, to test the stash prompt. `app.txt` will conflict.

### 5.2 Open the log

```bash
cd ~/cp-test && rabbitvcs log .
```

### 5.3 Test cases

| # | Do this | You should see |
|---|---|---|
| 1 | Look at the top left and bottom left | Branch name **ravi/task/new-update**, **All Branches** unticked, only 3 commits |
| 2 | Click the branch name → double-click **volza-bugfix-ejs-node** | That branch's history |
| 3 | Select the 3 "Volza 74674" commits → right-click | **Cherry Pick selected commits...** |
| 4 | Click it | **Cherry Pick** window, IDs 3, 2, 1 (1 is applied first) |
| 5 | Click a commit | **Revision Files** lists its files; **Commit Message** shows its message |
| 6 | Right-click **fix search API** → **Skip** | Its REBASE column says **Skip** |
| 7 | Click **Continue** | *"The current working tree is not clean…"* → **Stash** |
| 8 | (automatic) | **fix live errors** picked; **app change** conflicts: **Conflict Files** tab, button **Commit**, status **Rebasing... (3/3)** |
| 9 | Click **Commit** | *"One or more files are in a conflicted state."* |
| 10 | Right-click `app.txt` → **Edit conflicts** | Meld: Mine (left), result (middle), Theirs (right). Merge, save (Ctrl+S), close |
| 11 | (after Meld closes) | *"Are you sure you want to mark the conflicted file(s) as resolved?"* → **Yes**; status becomes **Modified** |
| 12 | Click **Commit** | If the message still has `# Conflicts:` lines: warning → **Abort**, delete those lines in **Commit Message**, click **Commit** again |
| 13 | (automatic) | Button **Done**, status **Done**, **Log** tab shown |
| 14 | Click **Done** | *"Do you want to stash pop now?"* → **Yes**; window closes and the log refreshes |

### 5.4 Check the result

```bash
cd ~/cp-test
git log --format='%h %an %s' -4   # app change, fix live errors, notes, my task work
git status --short                # M notes.txt  (your uncommitted edit is back)
ls fix2.txt                       # "No such file": it was skipped
```

### 5.5 Test Abort

Open the log again, pick a commit, and in the Cherry Pick window click **Abort** at any point after **Continue** → **Yes**. The branch goes back to exactly where it was.

### 5.6 Clean up

```bash
rm -rf ~/cp-test
```

---

## Daily use

Example: you are on `ravi/task/new-update` and need a fix from `volza-bugfix-ejs-node`.

1. Get the latest commits:
   ```bash
   git checkout ravi/task/new-update && git fetch origin
   ```
2. In Files, right-click in the repo folder → **RabbitVCS Git → Show Log**.
3. Click the branch name at the top left → **Browse References** → under **Remote branches → origin**, double-click **volza-bugfix-ejs-node**.
4. Select the commit(s) → right-click → **Cherry Pick this commit...** / **Cherry Pick selected commits...**
5. In the Cherry Pick window, set **Skip** / **Squash** / **Edit** if needed → **Continue**.
6. Handle any prompts as in the test above, then **Done**.
7. Push:
   ```bash
   git push origin ravi/task/new-update
   ```

Right-click the branch name → **HEAD -> "ravi/task/new-update"** to go back to your own branch.

---

## Remove

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
sudo apt install -y rabbitvcs-nautilus python3-nautilus meld
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/RaviVishwakarma12/rabbitvcs/installer/rabbitvcs-cherry-pick.sh)"
nautilus -q
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `curl: command not found` | `sudo apt install -y curl` |
| No RabbitVCS menu in Files | Run `nautilus -q`, then right-click inside a Git repo folder. If still missing, use `rabbitvcs log .` from the terminal (RabbitVCS 0.19 may not load in Nautilus 46+). |
| No branch name at the top left, or no Cherry Pick item | Run Step 4. If anything is missing, run Step 2 again. |
| Cherry Pick missing after `apt upgrade` | The update replaced RabbitVCS's files. Run Step 2 again. |
| Remote branches missing in Browse References | Run `git fetch origin` first. |
| **Edit conflicts** opens a text editor instead of a 3-way view | Install Meld: `sudo apt install -y meld`. A merge tool set in RabbitVCS Settings is used first if you have one. |
| RabbitVCS stops opening | Run the Remove command, then send the terminal output of `rabbitvcs log .` |

---

## Source

- Code: https://github.com/RaviVishwakarma12/rabbitvcs/tree/git-log-cherry-pick
- Installer: https://github.com/RaviVishwakarma12/rabbitvcs/tree/installer
- Once merged upstream and released, this comes with the normal `apt install` and the script isn't needed.
