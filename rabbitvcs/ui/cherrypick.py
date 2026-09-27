#
# This is an extension to the Nautilus file manager to allow better
# integration with the Subversion source control system.
#
# Copyright (C) 2006-2008 by Jason Field <jason@jasonfield.com>
# Copyright (C) 2007-2008 by Bruce van der Kooij <brucevdkooij@gmail.com>
# Copyright (C) 2008-2010 by Adam Plumb <adamplumb@gmail.com>
#
# RabbitVCS is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# RabbitVCS is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with RabbitVCS;  If not, see <http://www.gnu.org/licenses/>.
#
"""
Git cherry-pick, modelled on TortoiseGit's Cherry Pick dialog:

- choose which selected commits to pick, and their order
- optional "cherry picked from" line (-x), remembered between runs
- uncommitted changes are stashed first and restored afterwards
- merge commits ask which parent to use (-m)
- commits that end up empty can be committed anyway or skipped
- conflicts can be resolved, then Continue, Skip this commit or Abort
- Abort undoes every commit picked in this run

"""

import json
import os
import subprocess
import tempfile

from rabbitvcs import gettext

_ = gettext.gettext

PICKED = "picked"
SKIPPED = "skipped"
ABORT = "abort"
SKIP = "skip"
RETRY = "retry"
COMMIT = "commit"
CONTINUE = "continue"

CONFLICT_MARKERS = ("<<<<<<< ", ">>>>>>> ")
SETTINGS_FILE = "cherrypick.json"


class CherryPickResult:
    def __init__(self):
        self.status = "done"
        self.picked = []
        self.skipped = []
        self.notes = []


class CherryPicker:
    """
    Runs the cherry-pick one commit at a time. Every decision is delegated
    to ``ui``, so the logic can be driven by dialogs or by tests.

    """

    def __init__(self, path, ui):
        self.ui = ui
        self.cwd = path if os.path.isdir(path) else os.path.dirname(path)
        self.root = self.output("rev-parse", "--show-toplevel") or self.cwd

    def git(self, *args):
        proc = subprocess.run(
            ["git"] + list(args),
            cwd=self.cwd,
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.returncode, (proc.stdout + proc.stderr).strip()

    def output(self, *args):
        code, out = self.git(*args)
        return out if code == 0 else ""

    def current_branch(self):
        return self.output("rev-parse", "--abbrev-ref", "HEAD")

    def subject(self, commit):
        return self.output("log", "-1", "--format=%s", commit)

    def parents(self, commit):
        return self.output("rev-list", "--parents", "-n", "1", commit).split()[1:]

    def is_clean(self):
        code, out = self.git("status", "--porcelain", "--untracked-files=no")
        return code == 0 and out == ""

    def is_empty_commit(self, commit):
        parents = self.parents(commit)
        if len(parents) != 1:
            return False
        return self.output("rev-parse", commit + "^{tree}") == self.output(
            "rev-parse", parents[0] + "^{tree}"
        )

    def pick_in_progress(self):
        return self.git("rev-parse", "-q", "--verify", "CHERRY_PICK_HEAD")[0] == 0

    def conflicted_files(self):
        out = self.output("diff", "--name-only", "--diff-filter=U")
        return [line for line in out.splitlines() if line]

    def files_with_markers(self, files):
        found = []
        for name in files:
            path = os.path.join(self.root, name)
            if not os.path.isfile(path):
                continue
            with open(path, errors="ignore") as handle:
                if any(line.startswith(CONFLICT_MARKERS) for line in handle):
                    found.append(name)
        return found

    def merge_message(self):
        path = self.output("rev-parse", "--git-path", "MERGE_MSG")
        if path and not os.path.isabs(path):
            path = os.path.join(self.cwd, path)
        if path and os.path.isfile(path):
            with open(path, errors="ignore") as handle:
                return handle.read()
        return ""

    def commit(self, message=None, allow_empty=False):
        args = ["commit"]
        if allow_empty:
            args.append("--allow-empty")
        if message is None:
            return self.git(*(args + ["--no-edit"]))

        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            handle.write(message)
        try:
            return self.git(*(args + ["--cleanup=strip", "-F", handle.name]))
        finally:
            os.unlink(handle.name)

    def run(self, commits, add_cherry_picked_from=False):
        """
        @param commits: commit hashes, in the order they should be applied

        """
        result = CherryPickResult()
        if not commits:
            result.status = "nothing"
            return result

        stashed = False
        if not self.is_clean():
            if not self.ui.ask_stash():
                result.status = "cancelled"
                return result
            code, out = self.git("stash")
            if code:
                self.ui.error(out)
                result.status = "cancelled"
                return result
            stashed = True

        original_head = self.output("rev-parse", "HEAD")
        for commit in commits:
            outcome = self.pick(commit, add_cherry_picked_from)
            if outcome == PICKED:
                result.picked.append(commit)
            elif outcome == SKIPPED:
                result.skipped.append(commit)
            else:
                self.abort(original_head)
                result.status = "aborted"
                result.picked = []
                break

        if stashed:
            self.restore_stash(result)
        return result

    def pick(self, commit, add_cherry_picked_from):
        args = ["cherry-pick"]
        if add_cherry_picked_from:
            args.append("-x")

        parents = self.parents(commit)
        if len(parents) > 1:
            parent = self.ui.ask_parent(
                commit,
                self.subject(commit),
                [self.subject(p) for p in parents],
            )
            if not parent:
                return ABORT
            args += ["-m", str(parent)]
        elif self.is_empty_commit(commit):
            args.append("--allow-empty")
        args.append(commit)

        while True:
            code, out = self.git(*args)
            if code == 0:
                return PICKED
            if self.conflicted_files():
                return self.resolve_conflict(commit)
            if self.pick_in_progress():
                return self.handle_empty(commit)

            choice = self.ui.ask_failed(commit, self.subject(commit), out)
            if choice == RETRY:
                continue
            if choice == SKIP:
                self.git("reset", "--hard")
                return SKIPPED
            return ABORT

    def handle_empty(self, commit, message=None):
        choice = self.ui.ask_empty(commit, self.subject(commit))
        if choice == COMMIT:
            code, out = self.commit(message, allow_empty=True)
            if code:
                self.ui.error(out)
                return ABORT
            return PICKED
        if choice == SKIP:
            self.git("reset", "--hard")
            return SKIPPED
        return ABORT

    def resolve_conflict(self, commit):
        while True:
            choice, message = self.ui.ask_conflict(
                commit,
                self.subject(commit),
                self.conflicted_files(),
                self.merge_message(),
                self,
            )
            if choice == ABORT:
                return ABORT
            if choice == SKIP:
                self.git("reset", "--hard")
                return SKIPPED

            unresolved = self.files_with_markers(self.conflicted_files())
            if unresolved:
                self.ui.error(
                    _("These files still contain conflict markers:\n\n%s")
                    % "\n".join(unresolved)
                )
                continue

            remaining = self.conflicted_files()
            if remaining:
                self.git("add", "--", *remaining)

            if self.git("diff", "--cached", "--quiet")[0] == 0:
                return self.handle_empty(commit, message)

            code, out = self.commit(message)
            if code:
                self.ui.error(out)
                continue
            return PICKED

    def abort(self, original_head):
        if self.pick_in_progress():
            self.git("cherry-pick", "--abort")
        if original_head:
            self.git("reset", "--hard", original_head)

    def restore_stash(self, result):
        if not self.ui.ask_stash_pop():
            result.notes.append(
                _("Your uncommitted changes are saved in the stash. Run 'git stash pop' to restore them.")
            )
            return
        code, out = self.git("stash", "pop")
        if code:
            result.notes.append(
                _("Restoring your uncommitted changes failed:\n%s\n\nThey are still saved in the stash.")
                % out
            )


def load_add_cherry_picked_from():
    try:
        from rabbitvcs.util.settings import get_home_folder

        with open(os.path.join(get_home_folder(), SETTINGS_FILE)) as handle:
            return bool(json.load(handle).get("add_cherry_picked_from", False))
    except (OSError, ValueError, ImportError):
        return False


def save_add_cherry_picked_from(value):
    try:
        from rabbitvcs.util.settings import get_home_folder

        with open(os.path.join(get_home_folder(), SETTINGS_FILE), "w") as handle:
            json.dump({"add_cherry_picked_from": bool(value)}, handle)
    except (OSError, ImportError):
        pass


def short(commit):
    return commit[:8]


def trim(text, size=60):
    return text if len(text) <= size else text[: size - 1] + "…"


class GtkCherryPickUI:
    """Dialogs for CherryPicker, worded after TortoiseGit."""

    EDIT, THEIRS, MINE = 1, 2, 3

    def __init__(self, parent=None):
        from gi.repository import Gtk

        self.Gtk = Gtk
        self.parent = parent

    def message(self, title, text, buttons, kind=None):
        Gtk = self.Gtk
        dialog = Gtk.MessageDialog(
            transient_for=self.parent,
            modal=True,
            message_type=kind or Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.NONE,
            text=title,
        )
        dialog.set_title(_("Cherry Pick"))
        if text:
            dialog.format_secondary_text(text)
        for label, response in buttons:
            dialog.add_button(label, response)
        dialog.set_default_response(buttons[0][1])
        response = dialog.run()
        dialog.destroy()
        return response

    def error(self, text):
        self.message(
            _("Cherry Pick"), text, [(_("_OK"), 0)], self.Gtk.MessageType.ERROR
        )

    def ask_stash(self):
        return (
            self.message(
                _("The current working tree is not clean."),
                _("Do you want to stash the changes?"),
                [(_("_Stash"), 1), (_("_Abort"), 0)],
            )
            == 1
        )

    def ask_stash_pop(self):
        return (
            self.message(
                _("Do you want to stash pop now?"),
                _("Your uncommitted changes were stashed before cherry-picking."),
                [(_("_Yes"), 1), (_("_No"), 0)],
            )
            == 1
        )

    def ask_parent(self, commit, subject, parent_subjects):
        buttons = [
            (_("Parent %d: %s") % (i + 1, trim(s, 40)), i + 1)
            for i, s in enumerate(parent_subjects)
        ]
        response = self.message(
            f'"{short(commit)}" - "{trim(subject)}"',
            _("is a merge commit.\n\nWhich parent do you want to pick?"),
            buttons + [(_("_Cancel"), 0)],
        )
        return response if response > 0 else None

    def ask_empty(self, commit, subject):
        response = self.message(
            f"{short(commit)}  {trim(subject)}",
            _(
                "The current commit will be empty (its changes are already in "
                "this branch, or were dropped while resolving conflicts). Skip "
                "the commit or keep the message only commit?"
            ),
            [(_("C_ommit"), 1), (_("_Skip"), 2), (_("_Cancel"), 0)],
        )
        return {1: COMMIT, 2: SKIP}.get(response, ABORT)

    def ask_failed(self, commit, subject, output):
        response = self.message(
            _("Cherry-pick failed! Skip this commit?"),
            f"{short(commit)}  {trim(subject)}\n\n{output}",
            [(_("_Skip"), 1), (_("_Retry"), 2), (_("_Cancel"), 0)],
            self.Gtk.MessageType.WARNING,
        )
        return {1: SKIP, 2: RETRY}.get(response, ABORT)

    def ask_conflict(self, commit, subject, files, message, picker):
        Gtk = self.Gtk
        dialog = Gtk.Dialog(
            title=_("Cherry Pick - Conflict"), transient_for=self.parent, modal=True
        )
        dialog.set_default_size(720, 560)
        box = dialog.get_content_area()
        box.set_spacing(6)
        box.set_border_width(10)

        heading = Gtk.Label(xalign=0)
        title = _("Conflict while cherry-picking %s  %s") % (
            short(commit),
            GLibEscape(trim(subject, 70)),
        )
        heading.set_markup(f"<b>{title}</b>")
        box.pack_start(heading, False, False, 0)
        box.pack_start(
            Gtk.Label(
                label=_(
                    "Resolve the conflicted files, then click Continue.\n"
                    "Theirs = changes from the picked commit, Mine = your branch."
                ),
                xalign=0,
            ),
            False,
            False,
            0,
        )

        store = Gtk.ListStore(str)
        view = Gtk.TreeView(model=store)
        view.append_column(
            Gtk.TreeViewColumn(_("Conflicted files"), Gtk.CellRendererText(), text=0)
        )
        scroll = Gtk.ScrolledWindow()
        scroll.set_min_content_height(140)
        scroll.add(view)
        box.pack_start(scroll, True, True, 0)

        tools = Gtk.Box(spacing=6)
        for label, response in (
            (_("Edit Conflicts"), self.EDIT),
            (_("Resolve using Theirs"), self.THEIRS),
            (_("Resolve using Mine"), self.MINE),
        ):
            button = Gtk.Button(label=label)
            button.connect("clicked", lambda _b, r=response: dialog.response(r))
            tools.pack_start(button, False, False, 0)
        box.pack_start(tools, False, False, 0)
        view.connect(
            "row-activated", lambda *_a: dialog.response(self.EDIT)
        )

        box.pack_start(Gtk.Label(label=_("Commit message:"), xalign=0), False, False, 0)
        text = Gtk.TextView()
        text.set_monospace(True)
        text.get_buffer().set_text(message)
        text_scroll = Gtk.ScrolledWindow()
        text_scroll.set_min_content_height(140)
        text_scroll.add(text)
        box.pack_start(text_scroll, True, True, 0)

        dialog.add_button(_("_Abort"), 10)
        dialog.add_button(_("S_kip this commit"), 11)
        dialog.add_button(_("_Continue"), 12)
        dialog.show_all()

        def refresh():
            store.clear()
            for name in picker.conflicted_files():
                store.append([name])
            if len(store):
                view.get_selection().select_path(Gtk.TreePath(0))

        def selected():
            model, row = view.get_selection().get_selected()
            return model[row][0] if row else None

        refresh()
        while True:
            response = dialog.run()
            name = selected()
            if response == self.EDIT and name:
                from rabbitvcs.util import helper

                helper.launch_ui_window(
                    "editconflicts", [os.path.join(picker.root, name)]
                )
            elif response in (self.THEIRS, self.MINE) and name:
                side = "--theirs" if response == self.THEIRS else "--ours"
                code, out = picker.git("checkout", side, "--", name)
                if code == 0:
                    code, out = picker.git("add", "--", name)
                if code:
                    self.error(out)
                refresh()
            elif response in (10, 11, 12):
                buffer = text.get_buffer()
                msg = buffer.get_text(
                    buffer.get_start_iter(), buffer.get_end_iter(), False
                )
                dialog.destroy()
                return {10: ABORT, 11: SKIP, 12: CONTINUE}[response], msg
            elif response in (
                Gtk.ResponseType.DELETE_EVENT,
                Gtk.ResponseType.NONE,
            ):
                if self.message(
                    _("Abort the cherry-pick?"),
                    _("All commits picked in this run will be undone."),
                    [(_("_Abort"), 1), (_("_Keep resolving"), 0)],
                ) == 1:
                    dialog.destroy()
                    return ABORT, ""

    def select_commits(self, commits, branch, add_cherry_picked_from):
        """
        @param commits: list of (hash, subject, author) oldest first
        @return: (hashes to pick in order, add_cherry_picked_from) or None

        """
        Gtk = self.Gtk
        dialog = Gtk.Dialog(
            title=_("Cherry Pick"), transient_for=self.parent, modal=True
        )
        dialog.set_default_size(760, 420)
        box = dialog.get_content_area()
        box.set_spacing(6)
        box.set_border_width(10)

        heading = Gtk.Label(xalign=0)
        heading.set_markup(
            _("Cherry-pick onto branch: <b>%s</b>") % GLibEscape(branch)
        )
        box.pack_start(heading, False, False, 0)

        store = Gtk.ListStore(bool, str, str, str, str)
        for commit, subject, author in commits:
            store.append([True, short(commit), subject, author, commit])

        view = Gtk.TreeView(model=store)
        toggle = Gtk.CellRendererToggle()
        toggle.connect(
            "toggled", lambda _r, path: store.set_value(
                store.get_iter(path), 0, not store[path][0]
            )
        )
        view.append_column(Gtk.TreeViewColumn(_("Pick"), toggle, active=0))
        for title, index in ((_("Commit"), 1), (_("Message"), 2), (_("Author"), 3)):
            column = Gtk.TreeViewColumn(title, Gtk.CellRendererText(), text=index)
            column.set_resizable(True)
            column.set_expand(index == 2)
            view.append_column(column)

        scroll = Gtk.ScrolledWindow()
        scroll.set_vexpand(True)
        scroll.add(view)
        box.pack_start(scroll, True, True, 0)

        def move(offset):
            model, row = view.get_selection().get_selected()
            if not row:
                return
            index = model.get_path(row)[0] + offset
            if 0 <= index < len(model):
                other = model.get_iter(Gtk.TreePath(index))
                if offset < 0:
                    model.move_before(row, other)
                else:
                    model.move_after(row, other)

        tools = Gtk.Box(spacing=6)
        for label, offset in ((_("Move Up"), -1), (_("Move Down"), 1)):
            button = Gtk.Button(label=label)
            button.connect("clicked", lambda _b, o=offset: move(o))
            tools.pack_start(button, False, False, 0)
        tools.pack_start(
            Gtk.Label(label=_("Commits are applied from top to bottom.")),
            False,
            False,
            6,
        )
        box.pack_start(tools, False, False, 0)

        check = Gtk.CheckButton(label=_('Add "cherry picked from"'))
        check.set_active(add_cherry_picked_from)
        box.pack_start(check, False, False, 0)

        dialog.add_button(_("_Cancel"), Gtk.ResponseType.CANCEL)
        start = dialog.add_button(_("_Start Cherry Pick"), Gtk.ResponseType.OK)
        start.get_style_context().add_class("suggested-action")
        dialog.set_default_response(Gtk.ResponseType.OK)
        dialog.show_all()

        response = dialog.run()
        chosen = [row[4] for row in store if row[0]]
        add_from = check.get_active()
        dialog.destroy()
        if response != Gtk.ResponseType.OK:
            return None
        return chosen, add_from


def GLibEscape(text):
    from gi.repository import GLib

    return GLib.markup_escape_text(text)


def cherry_pick(path, commits, parent=None):
    """
    Entry point used by the log window.

    @param commits: list of (hash, subject, author), oldest first
    @return: True when the branch changed

    """
    ui = GtkCherryPickUI(parent)
    picker = CherryPicker(path, ui)
    branch = picker.current_branch()

    selection = ui.select_commits(commits, branch, load_add_cherry_picked_from())
    if selection is None:
        return False
    chosen, add_from = selection
    save_add_cherry_picked_from(add_from)
    if not chosen:
        return False

    result = picker.run(chosen, add_from)
    if result.status == "cancelled":
        return False

    if result.status == "aborted":
        summary = _("Cherry-pick aborted. '%s' was restored to its original state.") % branch
    else:
        summary = _("Cherry-pick finished on '%s': %d picked, %d skipped.") % (
            branch,
            len(result.picked),
            len(result.skipped),
        )
    ui.message(
        summary,
        "\n\n".join(result.notes),
        [(_("_OK"), 0)],
        ui.Gtk.MessageType.INFO,
    )
    return True
