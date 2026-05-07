# Promotion drafts

Post these from your own accounts. Tweak the wording so it sounds like you. The goal is honest signal, not hype.

Targets in order of likely return:
1. **r/ClaudeAI** (active, friendly to skill posts)
2. **Hacker News Show HN** (quality bar high, but one good comment thread = lots of stars)
3. **X/Twitter** (low effort, easy to thread)
4. Optional: **r/LocalLLaMA**, **r/MachineLearning** (if the post angle fits)

---

## Reddit r/ClaudeAI

**Title:** I built a skill that picks the right skill (skill-triage)

**Body:**

If you have a lot of Claude Code skills installed, you've probably hit the thing where Claude picks the first plausible one instead of the right one, or chains four "for safety" when one would do.

I made a small meta-skill called skill-triage that does the picking for you. Given a task, it:

- classifies it as simple / medium / complex / high-risk
- runs a frontmatter scanner across your installed skills
- ranks the top 1-3 candidates
- names the rejected ones with a one-line reason ("redundant with X", "post-impl only")
- emits a routing plan with phase ordering (pre / impl / post)
- stops and asks before anything destructive

The trick that actually changed behavior for me was a hard cap on how many skills can show up in the recommendation. Without it the routing turns into a directory dump. With it the model has to actually pick.

Apache 2.0, single SKILL.md plus a small bash scanner. Works with personal, plugin, and project skill dirs.

Repo: https://github.com/karankumar24/skill-triage

Happy to take feedback on the rubric or the scanner. The 4-tier complexity table is the thing I'm least sure about.

---

## Hacker News (Show HN)

**Title:** Show HN: Skill-triage – picks which Claude Code skill to use

**URL field:** https://github.com/karankumar24/skill-triage

**Text (optional, ~150 words):**

I kept hitting the same problem with Claude Code: too many skills installed, and the model would either pick the first plausible one or chain three together "for safety." So I wrote a meta-skill that triages.

It classifies the task on a 4-tier rubric (simple, medium, complex, high-risk), runs a small bash scanner to read frontmatter from every installed SKILL.md, and emits a routing plan: top 1-3 candidates, an "Avoid" list with reasons, and a verdict (proceed directly, proceed with skill, or stop and ask).

The hard cap on recommended skills was the load-bearing decision. Without it the model just lists every plausible match.

For destructive operations it gates with an `AskUserQuestion` and quotes the command verbatim instead of paraphrasing.

Apache 2.0. Feedback on the rubric and the YAML parsing in the scanner especially welcome.

---

## X / Twitter (3-tweet thread)

**Tweet 1:**
shipped a small thing today: skill-triage, a Claude Code meta-skill that picks the right skill for a task

if you've installed a bunch of skills you've felt the thrash. this is the cut.
https://github.com/karankumar24/skill-triage

**Tweet 2:**
the design call that actually mattered: a hard cap on how many skills can show up in the recommendation by complexity tier

simple = 0
medium = 1-2
complex = 3-5
high-risk = 1-2

without the cap the router just lists everything plausible. that's not routing, that's a directory dump.

**Tweet 3:**
also lists "skills to avoid" with reasons ("redundant with X", "post-impl only") so future-you doesn't reach for the wrong one ten minutes later

destructive ops always stop and ask. command is quoted verbatim, never paraphrased

Apache 2.0, contributions welcome

---

## Style notes (so it doesn't read as AI-written)

- Avoid em dashes. Use commas, parens, or two short sentences instead.
- Avoid "comprehensive", "robust", "powerful", "leverage", "showcase", "delve", "seamless".
- Avoid the rule of three (three-item bulleted phrases). Mix list lengths.
- First-person where natural. Talk about the actual problem you hit.
- One specific detail people can argue with (here: the skill budget cap, the YAML parser limitations) signals real authorship.
- Don't oversell. "Small thing", "feedback welcome", "least sure about X" reads honestly.

## After posting

Track stars: `gh repo view karankumar24/skill-triage --json stargazerCount`. Once at 10+, retry the travisvn/awesome-claude-skills PR. Check hesreallyhim/awesome-claude-code in 2-4 weeks for their reorg to land.
