# Notifications

Mainline posts a native macOS notification when something changes on a PR you track.
This page covers the events, how loud each one is, and how to keep the noise down.
Configure all of it in **Settings** → **Notifications**.

## Events

Mainline compares each poll against the previous one and notifies you on four kinds of change.
Each event has its own on/off toggle.

| Event                     | Fires when                                                              | Default |
| ------------------------- | ---------------------------------------------------------------------- | ------- |
| **New PR**                | A new PR matches one of your search queries.                           | On      |
| **Ready for review**      | A draft becomes ready, or you're added as a reviewer.                  | On      |
| **CI status changed**     | CI passes or fails on any tracked PR.                                  | On      |
| **New review or comment** | A review or comment is added to a tracked PR.                          | On      |

## Attention levels

Each event carries an attention level that sets how the notification behaves.
Set the level per event in **Settings** → **Notifications**.

| Level      | Behavior                                                    |
| ---------- | ---------------------------------------------------------- |
| **Notify** | A standard banner with sound.                             |
| **Quiet**  | A silent notification — it lands, but doesn't interrupt.   |

Setting each event independently lets you make a red CI a loud interruption while a new review request stays quiet.
By default, review requests are quiet and the rest notify.

## Filter out bot noise

Automated tools comment constantly — CodeRabbit, Vercel, dependabot, and code-review bots.
The **Only human comments** toggle keeps the "New review or comment" notification for people only.

- On (default) — bot and app activity never fires a comment notification.
- Off — every comment and review fires, including bots.

This affects notifications only.
Unread state and the menu bar badge still track every change.

## Postpone mutes notifications

When you postpone a PR (press `S`), Mainline stops notifying you about it — permanently.

The mute outlives the snooze window.
Even after the PR wakes and returns to its normal group, it never fires another banner.
Postponing is a signal of "I've dealt with this, stop telling me," so the mute is intentional and is never cleared automatically.

To learn the snooze durations and how to resume a postponed PR, see [Keyboard triage → Postpone and resume](./keyboard.md#postpone-and-resume).

## How the decision is made

The mapping from event to attention level is the **attention policy**.
Mainline stores it as a per-event table and falls back to the built-in defaults for any event you haven't changed.

Notifications use deterministic IDs, one per PR per event.
A rapid second poll replaces the existing banner rather than stacking a duplicate.
See [Architecture → Notifications](./architecture.md#notifications) for the internals.
