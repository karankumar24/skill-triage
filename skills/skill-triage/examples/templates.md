# Skill-triage worked examples

These examples are referenced from `SKILL.md` but live here so the main skill
body stays small (every token in SKILL.md persists in context for the rest of
the session — see https://code.claude.com/docs/en/skills).

> **Note.** Skill names in these examples (`writing-plans`, `careful`,
> `frontend-design`, `review`, `ship`, `brainstorming`) are placeholders.
> Substitute with whatever the scanner emits on the user's machine. If a
> placeholder skill is not installed, drop it from the recommendation — do not
> pretend it exists.

## Example 1 — medium task, single skill

User: "add a new column `last_login` to the users table and surface it in the profile page"

```markdown
## Routing plan

**Task:** Add users.last_login column and display on profile page.
**Complexity:** medium
**Risk flags:** none (dev DB; migration is additive, reversible)

**Relevant skills:**
- `writing-plans` — multi-file change with schema + UI; benefits from explicit phase plan

**Avoid:**
- `ship` — premature; nothing built yet
- `security-review` — additive non-sensitive column, no auth surface change

**Recommended order:**
1. **pre:** `/writing-plans` — break into migration + server action + UI tasks
2. **impl:** direct edits, no skill
3. **post:** `/review` — diff review before commit

**Verdict:** proceed with skill(s)
```

## Example 2 — high-risk, stop and ask

User: "drop the events table, we're not using it"

```markdown
## Routing plan

**Task:** DROP TABLE events from database.
**Complexity:** high-risk
**Risk flags:** destructive, irreversible (no backup mentioned)

**Relevant skills:**
- `careful` — wraps destructive commands with a confirmation gate

**Avoid:**
- a generic plan-execute skill — overkill for one-line SQL; bypasses the safety conversation

**Recommended order:**
1. **pre:** verify backup exists; confirm zero readers/writers in code
2. **impl:** `/careful` then issue DROP

**Verdict:** stop and ask
```

Then immediately invoke `AskUserQuestion`: "Destructive: `DROP TABLE events;`
is irreversible. Proceed?" with options: dry-run (count rows + grep
references), proceed after confirming backup, abort.

## Example 3 — simple, no skill

User: "rename `getUser` to `fetchUser` in src/api/user.ts"

```markdown
**Routing:** No skill needed — single-file mechanical rename, fully reversible. Proceeding directly.
```

## Example 4 — complex, multi-skill chain

User: "I want to ship a new dashboard page that pulls from our analytics warehouse and renders charts"

```markdown
## Routing plan

**Task:** Build analytics dashboard page with warehouse-backed charts and ship it.
**Complexity:** complex
**Risk flags:** none (new surface, additive)

**Relevant skills:**
- `brainstorming` — scope is fuzzy ("a dashboard"); needs requirements pass first
- `frontend-design` — distinctive UI required, not boilerplate
- `review` — pre-merge diff review
- `ship` — final merge + deploy step

**Avoid:**
- a second design skill — overlaps with `frontend-design`; pick one to avoid contradictory style guidance
- an autonomous-fix QA skill on first pass — better as report-only initially

**Recommended order:**
1. **pre:** `/brainstorming` — pin down dashboard scope, charts, data shape
2. **pre:** `/frontend-design` — design the page
3. **impl:** direct build
4. **post:** `/review` then `/ship`

**Verdict:** proceed with skill(s)
```
