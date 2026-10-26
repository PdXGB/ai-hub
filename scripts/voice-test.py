#!/usr/bin/env python3
"""voice-test.py: Home Assistant voice regression test for the LiteLLM local-ha route.

Sends fixed requests to LiteLLM the way Extended OpenAI Conversation 2.0.x does
(system prompt rendered from the HA prompt template with a frozen entity list,
the user's sentence, the execute_services tool) and checks the tool calls that
come back. Nothing is executed and nothing is sent to Home Assistant.

  voice-test.py                 run every case (3 runs each)
  voice-test.py --case dim-kitchen-40 --runs 1 -v
  voice-test.py --list          list the cases

Exit codes: 0 all passed, 1 a case failed or the HA model lost its pin,
2 setup error (missing key or files, LiteLLM unreachable).

Key: VOICE_TEST_KEY from the environment, else from /srv/ai/.env. Never printed.
Files: cases.json and extended-openai-prompt-template.txt next to this script
(/srv/ai/voice-test/), or the repo layout (home-assistant/...). See docs/05 §9.
"""
import argparse, datetime, json, os, re, statistics, sys, time, urllib.error, urllib.request

try:
    import jinja2
except ImportError:
    sys.exit("voice-test: needs python3-jinja2 (apt install python3-jinja2)")

HERE = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = "/srv/ai/.env"
CACHED_WARN_S = 2.0          # warn (not fail) above this median for cached requests


def find(name, *candidates):
    for c in candidates:
        if c and os.path.isfile(c):
            return c
    sys.exit(f"voice-test: can't find {name} (tried {', '.join(c for c in candidates if c)})")


def read_key(env_file):
    k = os.environ.get("VOICE_TEST_KEY", "").strip()
    if k:
        return k
    try:
        for line in open(env_file):
            m = re.match(r"\s*VOICE_TEST_KEY\s*=\s*(.*)", line)
            if m:
                return m.group(1).strip().strip("'\"")
    except OSError as e:
        print(f"voice-test: can't read {env_file}: {e.strerror} (run as the owner or with sudo)", file=sys.stderr)
    return ""


def render_prompt(template_text, entities, now):
    """Render like HA: exposed_entities, now(), and HA's regex 'match'/'search' tests."""
    env = jinja2.Environment()
    env.tests["match"] = lambda v, p: re.match(p, str(v)) is not None
    env.tests["search"] = lambda v, p: re.search(p, str(v)) is not None
    env.globals["now"] = lambda: now
    return env.from_string(template_text).render(
        exposed_entities=entities, ha_name="Home", current_device_id=None)


def post(url, key, body, timeout):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.load(r)
    return data, time.monotonic() - t0


def calls_of(message):
    """Flatten execute_services tool calls to [(service, entity, data)]. Unparseable -> ('?', raw, {})."""
    out = []
    for tc in message.get("tool_calls") or []:
        fn = tc.get("function") or {}
        name, raw = fn.get("name", ""), fn.get("arguments") or "{}"
        try:
            args = json.loads(raw) if isinstance(raw, str) else raw
        except ValueError:
            out.append(("?", f"{name}: bad JSON", {}))
            continue
        if name != "execute_services":
            out.append(("?", f"unknown function {name}", {}))
            continue
        items = args.get("list") if isinstance(args, dict) else None
        if not isinstance(items, list):
            out.append(("?", "no list[] in arguments", {}))
            continue
        for it in items:
            if not isinstance(it, dict):
                out.append(("?", "bad list item", {})); continue
            svc = f"{it.get('domain', '')}.{it.get('service', '')}"
            sd = dict(it.get("service_data") or {})
            ents = sd.pop("entity_id", [])
            if isinstance(ents, str):
                ents = [e.strip() for e in ents.split(",")]
            for e in ents or ["(none)"]:
                out.append((svc, e, sd))
    return out


def data_ok(want, got):
    for k, v in want.items():
        g = got.get(k)
        if g is None and k == "brightness_pct" and "brightness" in got:   # 0-255 scale
            try: g = round(float(got["brightness"]) * 100 / 255)
            except (TypeError, ValueError): g = None
        try:
            if g is None or abs(float(g) - float(v)) > (1 if k == "brightness_pct" else 0):
                return False
        except (TypeError, ValueError):
            return False
    return True


def check(case, message, calls, fx):
    """Return '' if the response passes, else a short reason."""
    kind, text = case["kind"], (message.get("content") or "").strip()
    unsafe = sorted({e for s, e, d in calls if e in fx["guarded"]})
    if kind in ("act", "multi", "confirm-yes"):
        if any(s == "?" for s, e, d in calls):
            return "bad tool call: " + "; ".join(e for s, e, d in calls if s == "?")
        if not calls:
            return f"no call (said: {text[:60]!r})"
        for want in case["expect"]:
            ok_svcs = [want["service"]] + fx["aliases"].get(want["service"], [])
            got = {e for s, e, d in calls if s in ok_svcs}
            if got != set(want["entities"]):
                return f"want {want['service']} {sorted(want['entities'])}, got {fmt(calls)}"
            if want.get("data") and not all(data_ok(want["data"], d) for s, e, d in calls if s in ok_svcs):
                return f"want data {want['data']}, got {fmt(calls)}"
        expected = {e for w in case["expect"] for e in w["entities"]}
        extra = [(s, e) for s, e, d in calls if e not in expected]
        if extra:
            return f"extra calls {extra}"
        return ""
    # no-call kinds: state, confirm, refuse, clarify
    if calls:
        return ("UNSAFE: " if unsafe else "") + f"called {fmt(calls)}"
    if not text:
        return "no call and no reply"
    if kind == "state" and not re.search(case["reply"], text, re.I):
        return f"reply doesn't match /{case['reply']}/: {text[:60]!r}"
    if kind in ("confirm", "clarify") and not re.search(r"\?|confirm|sure|which", text, re.I):
        return f"doesn't ask: {text[:60]!r}"
    return ""


def fmt(calls):
    return ", ".join(f"{s} {e}" + (f" {d}" if d else "") for s, e, d in calls) or "nothing"


def pin_status(ps_url):
    """ollama-ha /api/ps -> (ok, text). Forever = expires_at far in the future."""
    try:
        with urllib.request.urlopen(ps_url, timeout=10) as r:
            models = json.load(r).get("models", [])
    except (OSError, ValueError) as e:
        return None, f"couldn't read {ps_url} ({e})"
    if not models:
        return False, "no model loaded"
    out, ok = [], True
    for m in models:
        year = int(str(m.get("expires_at", "0000"))[:4] or 0)
        forever = year > 2100
        gpu = "100% GPU" if m.get("size_vram") == m.get("size") else f"{100 * m.get('size_vram', 0) // max(m.get('size', 1), 1)}% GPU"
        out.append(f"{m.get('name')} {gpu} {'Forever' if forever else 'until ' + str(m.get('expires_at'))}")
        ok = ok and forever
    return ok, "; ".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--url", default="http://localhost:4000/v1/chat/completions")
    ap.add_argument("--ps-url", default="http://localhost:11435/api/ps", help="ollama-ha, for the pin check")
    ap.add_argument("--no-pin-check", action="store_true")
    ap.add_argument("--cases", help="cases.json")
    ap.add_argument("--template", help="HA prompt template")
    ap.add_argument("--env-file", default=ENV_FILE)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--case", action="append", help="run only this case id (repeatable)")
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--json", metavar="FILE", help="write full results here")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true", help="print every reply")
    a = ap.parse_args()

    repo = os.path.join(HERE, "..", "home-assistant")
    cases_path = a.cases or find("cases.json", os.path.join(HERE, "cases.json"), os.path.join(repo, "voice-test", "cases.json"))
    tmpl_path = a.template or find("prompt template", os.path.join(HERE, "extended-openai-prompt-template.txt"),
                                   os.path.join(repo, "extended-openai-prompt-template.txt"))
    fx = json.load(open(cases_path))
    cases = [c for c in fx["cases"] if not a.case or c["id"] in a.case]
    if a.list:
        for c in fx["cases"]:
            print(f"{c['id']:16} {c['kind']:12} {c['say']}" + (f" -> {c['then']}" if c.get("then") else ""))
        return 0
    if not cases:
        sys.exit("voice-test: no matching cases")
    key = read_key(a.env_file)
    if not key:
        print("voice-test: no VOICE_TEST_KEY (environment or " + a.env_file + "); see docs/05 §9", file=sys.stderr)
        return 2

    now = datetime.datetime.fromisoformat(fx["now"])
    system = render_prompt(open(tmpl_path).read(), fx["entities"], now)
    tools = [{"type": "function", "function": f} for f in fx["functions"]]
    base = dict(fx["request"], tools=tools, tool_choice="auto")

    print(f"voice-test: {len(cases)} cases x {a.runs} runs -> {base['model']} ({len(system)} chars of system prompt)")
    results, lat, failed = [], [], 0
    for c in cases:
        runs = []
        for r in range(a.runs):
            msgs = [{"role": "system", "content": system}, {"role": "user", "content": c["say"]}]
            body = dict(base, messages=msgs, user=f"voice-test-{c['id']}-{r}")
            try:
                resp, secs = post(a.url, key, body, a.timeout)
                lat.append(secs)
                msg = resp["choices"][0]["message"]
                if c.get("then"):                       # second turn: history + the follow-up
                    if msg.get("tool_calls"):
                        reason = f"acted on turn 1: {fmt(calls_of(msg))}"
                        runs.append({"ok": False, "why": reason, "secs": secs}); continue
                    msgs += [{"role": "assistant", "content": msg.get("content") or ""},
                             {"role": "user", "content": c["then"]}]
                    resp, secs2 = post(a.url, key, dict(body, messages=msgs), a.timeout)
                    lat.append(secs2); secs += secs2
                    msg = resp["choices"][0]["message"]
                calls = calls_of(msg)
                why = check(c, msg, calls, fx)
                runs.append({"ok": not why, "why": why, "secs": round(secs, 2),
                             "reply": msg.get("content"), "calls": [list(x) for x in calls]})
                if a.verbose:
                    print(f"    {c['id']} run {r + 1}: {secs:.2f}s calls={fmt(calls)} reply={msg.get('content')!r}")
            except urllib.error.HTTPError as e:
                detail = e.read().decode(errors="replace")[:200]
                if e.code in (401, 403):
                    print(f"voice-test: LiteLLM refused the key ({e.code}): {detail}", file=sys.stderr); return 2
                runs.append({"ok": False, "why": f"HTTP {e.code}: {detail}", "secs": None})
            except (OSError, ValueError, KeyError, IndexError) as e:
                if not results and not runs:
                    print(f"voice-test: can't reach LiteLLM at {a.url}: {e}", file=sys.stderr); return 2
                runs.append({"ok": False, "why": f"error: {e}", "secs": None})
        ok = all(x["ok"] for x in runs)
        failed += not ok
        secs = [x["secs"] for x in runs if x["secs"] is not None]
        first_fail = next((x["why"] for x in runs if not x["ok"]), "")
        print(f"  {'PASS' if ok else 'FAIL'}  {c['id']:16} {c['kind']:12} {sum(x['ok'] for x in runs)}/{len(runs)}"
              f"  {max(secs) if secs else 0:5.2f}s  {first_fail}")
        results.append({"id": c["id"], "kind": c["kind"], "say": c["say"], "pass": ok, "runs": runs})

    cold = lat[0] if lat else 0
    cached = lat[1:]
    med = statistics.median(cached) if cached else 0
    print(f"latency: cold {cold:.2f}s, cached median {med:.2f}s, max {max(cached) if cached else 0:.2f}s ({len(lat)} requests)")
    if med > CACHED_WARN_S:
        print(f"WARNING: cached median above {CACHED_WARN_S}s")
    pin_ok, pin = (True, "not checked") if a.no_pin_check else pin_status(a.ps_url)
    print(f"ollama-ha pin: {pin}")
    total = len(results)
    print(f"RESULT: {total - failed}/{total} cases passed" + ("" if pin_ok is not False else "; HA model pin LOST"))
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"when": datetime.datetime.now().isoformat(timespec="seconds"), "model": base["model"],
                       "runs": a.runs, "latency": {"cold": cold, "cached_median": med, "all": lat},
                       "pin": pin, "cases": results}, f, indent=1)
    return 1 if failed or pin_ok is False else 0


if __name__ == "__main__":
    sys.exit(main())
