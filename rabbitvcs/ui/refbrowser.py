#
# This is an extension to the Nautilus file manager to allow better
# integration with the Subversion source control system.
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
Git reference picker for the log window, modelled on TortoiseGit:

- the current ref is shown at the top left of the log; click it to open
  "Browse References", right-click it for HEAD, FETCH_HEAD, All,
  All basic refs, All local branches and recently chosen refs
- an "All Branches" check box shows the log of every branch

"""

import json
import os
import subprocess
import time

from rabbitvcs import gettext

_ = gettext.gettext

MODE_REF = "ref"
MODE_ALL = "all"
MODE_BASIC = "basic"
MODE_LOCAL = "local"

MODE_LABELS = {
    MODE_ALL: _("<All Branches>"),
    MODE_BASIC: _("<Basic Refs>"),
    MODE_LOCAL: _("<Local Branches>"),
}

HISTORY_FILE = "log-refs.json"
HISTORY_SIZE = 10
GROUPS = (
    ("refs/heads/", _("Local branches")),
    ("refs/remotes/", _("Remote branches")),
    ("refs/tags/", _("Tags")),
)


def git_output(cwd, *args):
    proc = subprocess.run(
        ["git"] + list(args), cwd=cwd, capture_output=True, text=True, check=False
    )
    return proc.stdout.strip() if proc.returncode == 0 else ""


def repo_dir(path):
    return path if os.path.isdir(path) else os.path.dirname(path)


def strip_ref_name(ref):
    """Same display rule as TortoiseGit's StripRefName."""
    if ref.startswith("refs/heads/"):
        return ref[len("refs/heads/") :]
    if ref.startswith("refs/"):
        return ref[len("refs/") :]
    return ref


def current_branch(cwd):
    return git_output(cwd, "symbolic-ref", "--short", "-q", "HEAD")


def list_refs(cwd):
    out = git_output(
        cwd,
        "for-each-ref",
        "--format=%(refname)%00%(committerdate:unix)%00%(subject)",
        "refs/heads",
        "refs/remotes",
        "refs/tags",
    )
    refs = []
    for line in out.splitlines():
        parts = line.split("\0")
        if len(parts) != 3 or parts[0].endswith("/HEAD"):
            continue
        refs.append((parts[0], int(parts[1] or 0), parts[2]))
    return refs


def history_path():
    try:
        from rabbitvcs.util.settings import get_home_folder

        return os.path.join(get_home_folder(), HISTORY_FILE)
    except ImportError:
        return None


def load_history():
    path = history_path()
    try:
        with open(path) as handle:
            return [str(ref) for ref in json.load(handle)][:HISTORY_SIZE]
    except (OSError, TypeError, ValueError):
        return []


def add_history(ref):
    entries = [ref] + [r for r in load_history() if r != ref]
    path = history_path()
    if not path:
        return
    try:
        with open(path, "w") as handle:
            json.dump(entries[:HISTORY_SIZE], handle)
    except OSError:
        pass


def pick_ref(parent, cwd, selected=None):
    """
    The "Browse References" dialog.

    @return: the chosen ref as TortoiseGit shows it (e.g. "main" or
             "remotes/origin/main"), or None

    """
    from gi.repository import Gtk, Pango

    dialog = Gtk.Dialog(title=_("Browse References"), transient_for=parent, modal=True)
    dialog.set_default_size(720, 480)
    box = dialog.get_content_area()
    box.set_spacing(6)
    box.set_border_width(8)

    search = Gtk.SearchEntry()
    search.set_placeholder_text(_("Filter"))
    box.pack_start(search, False, False, 0)

    store = Gtk.TreeStore(str, str, str, str, int)
    current = "refs/heads/" + current_branch(cwd)
    groups = {}
    for prefix, label in GROUPS:
        groups[prefix] = store.append(None, [label, "", "", "", Pango.Weight.BOLD])
    remotes = {}
    for ref, date, subject in list_refs(cwd):
        prefix = next(p for p, _label in GROUPS if ref.startswith(p))
        parent_row = groups[prefix]
        name = ref[len(prefix) :]
        if prefix == "refs/remotes/" and "/" in name:
            remote, name = name.split("/", 1)
            if remote not in remotes:
                remotes[remote] = store.append(
                    parent_row, [remote, "", "", "", Pango.Weight.NORMAL]
                )
            parent_row = remotes[remote]
        stamp = time.strftime("%x %X", time.localtime(date)) if date else ""
        weight = Pango.Weight.BOLD if ref == current else Pango.Weight.NORMAL
        store.append(parent_row, [name, stamp, subject, ref, weight])

    filtered = store.filter_new()
    view = Gtk.TreeView(model=filtered)
    for title, index in ((_("Name"), 0), (_("Last Modified"), 1), (_("Message"), 2)):
        renderer = Gtk.CellRendererText()
        column = Gtk.TreeViewColumn(title, renderer, text=index, weight=4)
        column.set_resizable(True)
        column.set_expand(index == 2)
        view.append_column(column)

    def visible(model, row, _data):
        text = search.get_text().lower()
        if not text:
            return True
        if model[row][3]:
            return text in model[row][3].lower()
        child = model.iter_children(row)
        while child:
            if visible(model, child, None):
                return True
            child = model.iter_next(child)
        return False

    filtered.set_visible_func(visible)
    search.connect("search-changed", lambda *_a: (filtered.refilter(), view.expand_all()))

    scroll = Gtk.ScrolledWindow()
    scroll.set_vexpand(True)
    scroll.add(view)
    box.pack_start(scroll, True, True, 0)
    view.expand_all()

    def select(model, path, row, _data):
        if model[row][3] and strip_ref_name(model[row][3]) == selected:
            view.get_selection().select_path(path)
            view.scroll_to_cell(path, None, True, 0.5, 0)
            return True
        return False

    filtered.foreach(select, None)

    dialog.add_button(_("_Cancel"), Gtk.ResponseType.CANCEL)
    dialog.add_button(_("_OK"), Gtk.ResponseType.OK)
    dialog.set_default_response(Gtk.ResponseType.OK)
    view.connect(
        "row-activated",
        lambda _v, path, _c: filtered[path][3] and dialog.response(Gtk.ResponseType.OK),
    )
    dialog.show_all()

    result = None
    while True:
        response = dialog.run()
        if response != Gtk.ResponseType.OK:
            break
        model, row = view.get_selection().get_selected()
        if row and model[row][3]:
            result = strip_ref_name(model[row][3])
            break
    dialog.destroy()
    return result


class RefSelector:
    """
    The ref label at the top left of the log window plus the "All Branches"
    check box at the bottom left. ``on_change`` is called after any change.

    """

    def __init__(self, path, parent_window, on_change):
        from gi.repository import Gtk

        self.Gtk = Gtk
        self.cwd = repo_dir(path)
        self.parent_window = parent_window
        self.on_change = on_change
        self.mode = MODE_REF
        self.ref = "HEAD"

        self.button = Gtk.Button()
        self.button.set_relief(Gtk.ReliefStyle.NONE)
        self.button.set_tooltip_text(
            _("Click to browse references. Right-click for more choices.")
        )
        self.button.connect("clicked", lambda *_a: self.browse())
        self.button.connect("button-press-event", self.on_button_press)

        self.all_branches = Gtk.CheckButton(label=_("_All Branches"), use_underline=True)
        self.all_branches.connect("toggled", self.on_all_toggled)
        self.updating = False
        self.update_widgets()

    def log_arguments(self, git):
        """Keyword arguments for rabbitvcs.vcs.git.Git.log()."""
        if self.mode == MODE_REF:
            return {"revision": git.revision(self.ref), "showtype": "branch"}
        if self.mode == MODE_ALL:
            return {"showtype": "all"}
        return {"showtype": self.mode}

    def label(self):
        if self.mode != MODE_REF:
            return MODE_LABELS[self.mode]
        if self.ref == "HEAD":
            return current_branch(self.cwd) or _("No branch")
        return self.ref

    def update_widgets(self):
        self.updating = True
        self.button.set_label(self.label())
        self.all_branches.set_inconsistent(self.mode in (MODE_BASIC, MODE_LOCAL))
        self.all_branches.set_active(self.mode == MODE_ALL)
        self.updating = False

    def set_mode(self, mode, ref="HEAD"):
        self.mode = mode
        self.ref = ref
        self.update_widgets()
        self.on_change()

    def on_all_toggled(self, check):
        if self.updating:
            return
        if self.mode == MODE_REF:
            self.set_mode(MODE_ALL)
        else:
            self.set_mode(MODE_REF, "HEAD")

    def browse(self):
        ref = pick_ref(self.parent_window, self.cwd, self.ref)
        if ref:
            add_history(ref)
            self.set_mode(MODE_REF, ref)

    def on_button_press(self, _widget, event):
        if event.button != 3:
            return False
        Gtk = self.Gtk
        menu = Gtk.Menu()

        def item(label, callback, sensitive=True):
            entry = Gtk.MenuItem(label=label)
            entry.set_sensitive(sensitive)
            entry.connect("activate", lambda *_a: callback())
            menu.append(entry)

        item(_("Browse references"), self.browse)
        branch = current_branch(self.cwd)
        head = f'HEAD -> "{branch}"' if branch else "HEAD"
        item(head, lambda: self.set_mode(MODE_REF, "HEAD"))
        has_fetch_head = bool(git_output(self.cwd, "rev-parse", "-q", "--verify", "FETCH_HEAD"))
        item("FETCH_HEAD", lambda: self.set_mode(MODE_REF, "FETCH_HEAD"), has_fetch_head)
        item(_("All"), lambda: self.set_mode(MODE_ALL))
        item(_("All basic refs"), lambda: self.set_mode(MODE_BASIC))
        item(_("All local branches"), lambda: self.set_mode(MODE_LOCAL))
        history = load_history()
        if history:
            menu.append(Gtk.SeparatorMenuItem())
            for ref in history:
                item(ref, lambda r=ref: (add_history(r), self.set_mode(MODE_REF, r)))
        menu.show_all()
        menu.popup_at_pointer(event)
        return True
