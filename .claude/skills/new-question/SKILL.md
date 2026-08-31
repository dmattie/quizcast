---
name: new-question
description: Add a question to a Quizcast quiz, or scaffold a whole new quiz folder. Use when asked to write quiz questions, add a question about a topic, or start a new quiz for a lecture.
argument-hint: [quiz-slug] [topic]
allowed-tools: Bash(ls:*), Bash(make test)
---

## Existing quizzes

!`ls -d quizzes/*/ 2>/dev/null || echo "none yet"`

## Task

Add a question to `$0` about `$1`. If `$0` names a folder that doesn't exist,
create it with a `quiz.yaml` first. If no arguments were given, ask which quiz
and what topic before writing anything.

## Format

Write the file as `quizzes/<slug>/NN-short-name.md`, where `NN` continues the
existing numbering. Files are ordered by filename, so the number is what sets
question order.

```markdown
---
time_limit: 30
points: 1000
---

# The question, as a full sentence ending in a question mark.

- [ ] A plausible wrong answer
- [x] The correct answer
- [ ] Another plausible wrong answer
- [ ] A fourth option

> One or two sentences on why the answer is right. Cite the source where there
> is one.
```

Optional: `media:` in the frontmatter for an external image URL (add `media_alt`
alongside it), and a plain paragraph between the prompt and the options for
context. Both are described in `README.md`.

## Rules

- Mark exactly one answer with `- [x]` unless a select-all question is wanted.
  Two or more marks turns it into an exact-match multi-select automatically.
- Distractors must be plausible to someone who half-knows the material.
  An obviously silly option wastes the question.
- Four options is the default. Five is fine. Two is a coin flip, so avoid it.
- The prompt goes on the projector at a large size. Keep it under about 20
  words so it fits without shrinking.
- Raise `time_limit` for questions that need reading, such as anything with a
  figure or a context paragraph. It affects scoring only; the host still
  controls when the question closes.
- Write the explanation for the room, not for the answer key. It gets read out.

## After writing

Run `make test` to confirm the file parses. A malformed question is caught by
the parser, not at the projector.
