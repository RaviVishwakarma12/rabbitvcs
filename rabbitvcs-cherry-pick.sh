#!/usr/bin/env bash
# Adds "Cherry-pick this commit" to the RabbitVCS Show Log right-click menu.
# Usage:  sudo bash rabbitvcs-cherry-pick.sh           (install)
#         sudo bash rabbitvcs-cherry-pick.sh --remove  (restore original)
set -euo pipefail

TARGET_DIR="/usr/lib/python3/dist-packages"
FILES=(rabbitvcs/ui/log.py rabbitvcs/util/contextmenuitems.py)
BACKUP_SUFFIX=".orig-cherrypick"

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
cd "$TARGET_DIR"

if [[ "${1:-}" == "--remove" ]]; then
  for f in "${FILES[@]}"; do
    [[ -f "$f$BACKUP_SUFFIX" ]] && mv "$f$BACKUP_SUFFIX" "$f"
  done
  echo "Original RabbitVCS files restored."
  exit 0
fi

if grep -q "MenuCherryPick" rabbitvcs/util/contextmenuitems.py; then
  echo "Cherry-pick patch is already installed."
  exit 0
fi

for f in "${FILES[@]}"; do cp -p "$f" "$f$BACKUP_SUFFIX"; done

patch -p1 --forward <<'PATCH'
diff --git a/rabbitvcs/ui/log.py b/rabbitvcs/ui/log.py
index 4e085f5..6d0ab59 100755
--- a/rabbitvcs/ui/log.py
+++ b/rabbitvcs/ui/log.py
@@ -36,6 +36,7 @@ from rabbitvcs.ui import InterfaceView
 from gi.repository import Gtk, GObject, Gdk
 import six
 import threading
+import subprocess
 from locale import strxfrm
 
 import os.path
@@ -1181,6 +1182,9 @@ class LogTopContextMenuConditions(object):
     def reset(self, data=None):
         return self.vcs_name == rabbitvcs.vcs.VCS_GIT
 
+    def cherry_pick(self, data=None):
+        return self.vcs_name == rabbitvcs.vcs.VCS_GIT
+
 
 class LogTopContextMenuCallbacks(object):
     def __init__(self, caller, vcs, path, revisions):
@@ -1424,6 +1428,49 @@ class LogTopContextMenuCallbacks(object):
             ],
         )
 
+    def cherry_pick(self, widget, data=None):
+        from rabbitvcs.ui.dialog import Confirmation
+
+        cwd = self.path if os.path.isdir(self.path) else os.path.dirname(self.path)
+
+        def git(*args):
+            proc = subprocess.run(
+                ["git"] + list(args), cwd=cwd, capture_output=True, text=True
+            )
+            return proc.returncode, (proc.stdout + proc.stderr).strip()
+
+        # Log lists newest first; cherry-pick oldest first to keep order.
+        commits = [S(r["revision"]) for r in reversed(self.revisions)]
+        _code, branch = git("rev-parse", "--abbrev-ref", "HEAD")
+        summary = "\n".join(
+            "%s  %s" % (c[:8], S(r["message"]).split("\n")[0][:60])
+            for c, r in zip(commits, reversed(self.revisions))
+        )
+
+        prompt = _("Cherry-pick %d commit(s) onto '%s'?\n\n%s") % (
+            len(commits),
+            branch,
+            summary,
+        )
+        if Confirmation(prompt).run() != Gtk.ResponseType.OK:
+            return
+
+        code, output = git("cherry-pick", *commits)
+        if code == 0:
+            MessageBox(_("Cherry-pick completed.\n\n%s") % output)
+            self.caller.load()
+            return
+
+        abort_prompt = _(
+            "Cherry-pick stopped (conflict or error):\n\n%s\n\n"
+            "Click OK to abort and restore the branch, or Cancel to keep the "
+            "conflict and resolve it yourself (then commit, or run "
+            "'git cherry-pick --continue')."
+        ) % output
+        if Confirmation(abort_prompt).run() == Gtk.ResponseType.OK:
+            git("cherry-pick", "--abort")
+        self.caller.load()
+
     def edit_author(self, widget, data=None):
         author = ""
         if len(self.revisions) == 1:
@@ -1527,6 +1574,7 @@ class LogTopContextMenu(object):
             (MenuExport, None),
             (MenuMerge, None),
             (MenuReset, None),
+            (MenuCherryPick, None),
             (MenuSeparatorLast, None),
             (MenuEditAuthor, None),
             (MenuEditLogMessage, None),
diff --git a/rabbitvcs/util/contextmenuitems.py b/rabbitvcs/util/contextmenuitems.py
index b90b66e..8da52ac 100644
--- a/rabbitvcs/util/contextmenuitems.py
+++ b/rabbitvcs/util/contextmenuitems.py
@@ -786,6 +786,12 @@ class MenuReset(MenuItem):
     icon = "rabbitvcs-reset"
 
 
+class MenuCherryPick(MenuItem):
+    identifier = "RabbitVCS::Cherry_Pick"
+    label = _("Cherry-pick this commit")
+    icon = "rabbitvcs-merge"
+
+
 class MenuStage(MenuItem):
     identifier = "RabbitVCS::Stage"
     label = _("Stage")
PATCH

python3 -m py_compile "${FILES[@]}"
pkill -f "rabbitvcs/services/[c]heckerservice" 2>/dev/null || true
nautilus -q 2>/dev/null || true
echo "Done. Open Show Log, right-click a commit, choose 'Cherry-pick this commit'."
