# RabbitVCS with TortoiseGit-style Cherry Pick on Ubuntu

RabbitVCS is the Linux version of TortoiseGit: it adds Git options to the right-click menu in the Files app.
Ubuntu's RabbitVCS has no cherry-pick. The `rabbitvcs-cherry-pick.sh` script adds TortoiseGit's cherry-pick flow to the **Show Log** window:

| Feature | Same as TortoiseGit |
|---|---|
| **Branch** dropdown: shows commits from a chosen branch that are not yet in your current branch | Log branch/ref filter |
| **Cherry Pick this commit...** / **Cherry Pick selected commits...** in the right-click menu | Same menu labels |
| **Cherry Pick dialog**: tick or untick each commit, **Move Up/Down** to reorder | Pick / Skip and reordering |
| **Add "cherry picked from"** option (`-x`), remembered for next time | Same option |
| Uncommitted changes: *"The current working tree is not clean. Do you want to stash the changes?"* and at the end *"Do you want to stash pop now?"* | Same prompts |
| Merge commits (for example "Merge pull request #..."): choose **Parent 1** or **Parent 2** | Same choice |
| Commit becomes empty (already in your branch): **Commit** / **Skip** / **Cancel** | Same choice |
| Conflicts: **Edit Conflicts** (3-way merge: Mine / file / Theirs), **Resolve using Theirs / Mine**, editable commit message, then **Continue**, **Skip this commit** or **Abort** | Same flow |
| **Abort** puts your branch back exactly as it was before the run | Same |

Not included: TortoiseGit's **Squash** and **Edit** per-commit actions.

---

## Step 1: Install RabbitVCS

```bash
sudo apt update
sudo apt install -y rabbitvcs-nautilus python3-nautilus curl meld
```

`meld` is the 3-way merge tool that **Edit Conflicts** opens.

> `SyntaxWarning` lines during the install are harmless. The install succeeded if you see `Setting up rabbitvcs-nautilus ...`.

---

## Step 2: Add cherry-pick (one command, also upgrades older versions)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/RaviVishwakarma12/rabbitvcs/installer/rabbitvcs-cherry-pick.sh)"
```

The last line should be:

```
Done. Open Show Log, choose a branch in the 'Branch' dropdown, right-click a commit, choose 'Cherry Pick this commit...'.
```

Running it again is safe. It prints `Cherry-pick patch is already installed and up to date.`

---

## Step 3: Restart Files

```bash
nautilus -q
```

---

## Step 4: Verify the install

```bash
cat /usr/lib/python3/dist-packages/rabbitvcs/.cherry-pick-patch
ls /usr/lib/python3/dist-packages/rabbitvcs/ui/cherrypick.py
grep -c "Cherry Pick selected commits" /usr/lib/python3/dist-packages/rabbitvcs/util/contextmenuitems.py
```

Expected: a version code (for example `290d5c13b702`), the file path, and `1`.

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
echo "work in progress" > notes.txt && git add notes.txt && git commit -qm "notes"
echo "uncommitted edit" >> notes.txt
```

The last line leaves an uncommitted change, to test the stash prompt.

### 5.2 Open the log window

```bash
cd ~/cp-test && rabbitvcs log .
```

Keep the terminal open. Any error shows there.

### 5.3 Test cases

| # | Do this | You should see |
|---|---|---|
| 1 | **Branch** dropdown → **feature** | Only 3 commits: `add extra.txt`, `add more.txt`, `change app.txt (feature)` |
| 2 | Click the first commit, Shift+click the last, right-click | Menu item **Cherry Pick selected commits...** |
| 3 | Click it | **Cherry Pick** dialog: "Cherry-pick onto branch: **main**", 3 ticked commits, oldest first |
| 4 | Untick **add more.txt**, tick **Add "cherry picked from"**, click **Start Cherry Pick** | *"The current working tree is not clean. Do you want to stash the changes?"* |
| 5 | Click **Stash** | `add extra.txt` is picked, then the **Conflict** dialog for `change app.txt (feature)` with `app.txt` listed |
| 6 | Click **Continue** without resolving | Error: *"These files still contain conflict markers: app.txt"*. Click OK |
| 7 | Select `app.txt` → **Edit Conflicts** | Meld opens: Mine (left), the file to fix (middle), Theirs (right). Close it without saving |
| 8 | **Resolve using Theirs** → **Continue** | *"Do you want to stash pop now?"* |
| 9 | Click **Yes** | *"Cherry-pick finished on 'main': 2 picked, 0 skipped."* and the log refreshes |

### 5.4 Check the result

```bash
cd ~/cp-test
git log --format='%h %s' -3    # change app.txt (feature), add extra.txt, notes
git log -1 --format=%B         # message ends with "(cherry picked from commit ...)"
cat app.txt                    # feature change
git status --short             # M notes.txt  (your uncommitted edit is back)
ls more.txt                    # "No such file": it was unticked
```

### 5.5 Test Abort

```bash
cd ~/cp-test
git reset -q --hard HEAD~2 && git checkout -q -- . && git stash clear
rabbitvcs log .
```

Choose **feature**, right-click **change app.txt (feature)** → **Cherry Pick this commit...** → **Start Cherry Pick** → in the Conflict dialog click **Abort**.
Expected: *"Cherry-pick aborted. 'main' was restored to its original state."* and `git status` is clean.

### 5.6 Clean up

```bash
rm -rf ~/cp-test
```

---

## Daily use

Example: you are on `ravi/task/new-update` and need a fix from `volza-bugfix-ejs-node`.

1. Switch to your branch and fetch:
   ```bash
   git checkout ravi/task/new-update && git fetch origin
   ```
2. In Files, right-click in the repo folder → **RabbitVCS Git → Show Log**.
3. **Branch** dropdown → **origin/volza-bugfix-ejs-node**. Only commits that branch has and yours doesn't are listed.
4. Select the commit(s) → right-click → **Cherry Pick this commit...** (or **selected commits...**).
5. In the dialog, check it says **onto branch: ravi/task/new-update**, untick anything you don't want → **Start Cherry Pick**.
6. Handle any prompt (stash, merge parent, conflict) as in the tests above.
7. Push:
   ```bash
   git push origin ravi/task/new-update
   ```

Choose **All branches** in the dropdown to go back to the full log.

> Picked commits drop out of the Branch list automatically. A commit picked with a conflict resolution may still be listed, because its final change differs from the original.

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
sudo apt install -y rabbitvcs-nautilus python3-nautilus
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/RaviVishwakarma12/rabbitvcs/installer/rabbitvcs-cherry-pick.sh)"
nautilus -q
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `curl: command not found` | `sudo apt install -y curl` |
| No RabbitVCS menu in Files | Run `nautilus -q`, then right-click inside a Git repo folder. If still missing, use `rabbitvcs log .` from the terminal (RabbitVCS 0.19 may not load in Nautilus 46+). |
| No Branch dropdown or no Cherry Pick item | Run Step 4. If anything is missing, run Step 2 again. |
| Cherry-pick missing after `apt upgrade` | The update replaced RabbitVCS's files. Run Step 2 again. |
| RabbitVCS stops opening | Run the Remove command, then send the terminal output of `rabbitvcs log .` |
| **Edit Conflicts** opens a text editor instead of a 3-way view | Meld isn't installed: `sudo apt install -y meld`. It uses the merge tool from RabbitVCS Settings if you set one. You can also fix the conflict markers in any editor, save, then click **Continue**. |

---

## Source

- Code: https://github.com/RaviVishwakarma12/rabbitvcs/tree/git-log-cherry-pick
- Installer: https://github.com/RaviVishwakarma12/rabbitvcs/tree/installer
- Once merged upstream and released, cherry-pick will come with the normal `apt install` and this script won't be needed.
