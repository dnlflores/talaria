"""Talaria push. Everything lives in dashboard/: the routes the phone registers with
(dashboard/plugin_api.py) and the watcher they start. Agent sessions get nothing from this plugin."""


def register(ctx):  # noqa: ARG001 -- no tools, hooks or commands
    return None
