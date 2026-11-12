"""Records what Hermes actually sends for each thinking effort, per model, for ReasoningLevelsTests.

Hermes does not publish which efforts a model takes: every route fits its one ladder (Off,
Minimal, Low, Medium, High, Extra high, Max, Ultra) to the model, so several rungs can send the
same request. This asks the backend's own request builders what each rung sends for every model
in a catalog, groups rungs that send the same thing, and prints the rows of
`ReasoningLevelsTests.recorded`. Rerun it after a Hermes update; a failing test then means
`ReasoningLevels` needs the new rule.

usage (from the hermes-agent checkout, with its venv):
  node scripts/model-catalog.mjs /tmp/catalog.json
  cd ~/.hermes/hermes-agent && venv/bin/python <talaria>/scripts/record-effort-levels.py /tmp/catalog.json
"""
import importlib.util
import json
import sys

sys.path.insert(0, ".")
from hermes_constants import parse_reasoning_effort  # noqa: E402

ON = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
PREFER = ["low", "medium", "high", "xhigh", "max", "minimal", "ultra"]
LOCAL = ("llamacpp", "custom", "local", "ollama", "vllm")


def group(wire_of):
    """Rungs grouped by the request they send; each group shown as its own name when the request
    names it, else its most common rung."""
    groups = {}
    for level in ON:
        groups.setdefault(wire_of(level), []).append(level)
    shown = []
    for wire, members in groups.items():
        named = [m for m in members if f'"{m}"' in wire]
        pick = named[0] if len(named) == 1 else next(m for m in PREFER if m in members)
        shown.append({"value": pick, "also": [m for m in members if m != pick]})
    return sorted(shown, key=lambda level: ON.index(level["value"]))


def anthropic(model):
    from agent.anthropic_adapter import _supports_adaptive_thinking, build_anthropic_kwargs

    def kwargs(effort):
        k = build_anthropic_kwargs(model=model, messages=[{"role": "user", "content": "hi"}], tools=None,
                                   max_tokens=None, reasoning_config=parse_reasoning_effort(effort))
        return {key: k[key] for key in ("thinking", "output_config") if key in k}

    if not any(kwargs(e) for e in ON):
        return {"off": False, "levels": []}
    off = kwargs("none")
    # Adaptive models think unless the disable is sent; older ones only think when asked.
    off_ok = off.get("thinking", {}).get("type") in ("disabled", "between_tools") or (
        not _supports_adaptive_thinking(model) and not off)
    return {"off": off_ok, "levels": group(lambda e: json.dumps(kwargs(e), sort_keys=True))}


def codex(model):
    from agent.transports.codex import _resolve_reasoning

    def resolve(effort):
        return _resolve_reasoning(model, {
            "reasoning_config": parse_reasoning_effort(effort), "is_codex_backend": True,
            "base_url": "https://chatgpt.com/backend-api/codex", "provider": "openai-codex"})

    effort, enabled = resolve("none")
    return {"off": effort == "none" and not enabled, "levels": group(lambda e: json.dumps(resolve(e)))}


def custom(model):
    spec = importlib.util.spec_from_file_location("custom_profile", "plugins/model-providers/custom/__init__.py")
    assert spec is not None and spec.loader is not None, "run from the hermes-agent checkout"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    profile = module.CustomProfile.__new__(module.CustomProfile)
    from agent.transports.chat_completions import _reasoning_config_for_model

    def extras(effort):
        rc = _reasoning_config_for_model(model, parse_reasoning_effort(effort))
        return json.dumps(profile.build_api_kwargs_extras(reasoning_config=rc, base_url="http://127.0.0.1:8080/v1"),
                          sort_keys=True, default=str)

    return {"off": '"none"' in extras("none"), "levels": group(extras)}


def openai_compat(model, can_disable):
    from agent.transports.chat_completions import _reasoning_config_for_model

    def sent(effort):
        return json.dumps(_reasoning_config_for_model(model, parse_reasoning_effort(effort)), sort_keys=True)

    return {"off": can_disable is not False, "levels": group(sent)}


def main():
    catalog = json.load(open(sys.argv[1]))
    for provider in catalog["providers"]:
        slug = provider["slug"]
        caps = provider.get("capabilities") or {}
        seen = set()
        for model in provider.get("models") or []:
            cap = caps.get(model) or {}
            if not cap.get("reasoning") or slug == "antigravity-agy":
                result = {"off": False, "levels": []}
            elif slug == "anthropic":
                result = anthropic(model)
            elif slug == "openai-codex":
                result = codex(model)
            elif slug in LOCAL:
                result = custom(model)
            else:
                result = openai_compat(model, cap.get("can_disable_reasoning"))
            # One row per distinct answer on routes whose rules do not depend on the model's name.
            key = json.dumps([result, cap.get("can_disable_reasoning"), cap.get("reasoning")])
            if slug not in ("anthropic", "openai-codex"):
                if key in seen:
                    continue
                seen.add(key)
            encoded = (["none"] if result["off"] else []) + ["+".join([l["value"]] + l["also"]) for l in result["levels"]]
            flag = cap.get("can_disable_reasoning")
            print(f'    ("{slug}", "{model}", {str(bool(cap.get("reasoning"))).lower()}, '
                  f'{"nil" if flag is None else str(flag).lower()}, "{" ".join(encoded)}"),')


if __name__ == "__main__":
    main()
