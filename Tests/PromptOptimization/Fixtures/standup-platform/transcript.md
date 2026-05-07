**Marcus Chen** _[0:00]_

Morning everyone. Quick standup. Let's go around — Priya, you start.

**Priya Singh** _[0:08]_

Yesterday I shipped the v2 webhook retry logic. Today I'm picking up the database connection pooling work — we're seeing pool exhaustion in production around peak hours. I'll have a draft PR by end of day. No blockers.

**Marcus Chen** _[0:32]_

Great. Dave?

**Dave Kim** _[0:35]_

Yesterday I was on call. We had a P1 around 3am — turned out to be an upstream rate-limit on the Stripe webhook endpoint. I documented it in the runbook. Today I'll be working on the OAuth token refresh bug Sarah filed last week. Blocker — I need someone to repro it on staging. Sarah, can you walk me through it after standup?

**Sarah Walker** _[1:14]_

Yeah, let's grab 10 minutes at 10:30. I'll send a calendar invite.

**Dave Kim** _[1:21]_

Perfect.

**Marcus Chen** _[1:24]_

Sarah, you want to go next?

**Sarah Walker** _[1:27]_

Yesterday I finished the auth audit log work — that's deployed to staging, waiting on security review. Today I'm continuing the multi-tenant data export — should have it ready for review by Wednesday. I do need a decision from Marcus on whether we want to support CSV or just JSON for the v1 export. Marcus, what's the call?

**Marcus Chen** _[1:54]_

Let's do JSON only for v1. CSV adds escaping complexity I don't want to deal with on this ship date. We can add CSV in v1.1 if customers ask.

**Sarah Walker** _[2:05]_

Got it. JSON only.

**Marcus Chen** _[2:08]_

Last but not least — me. Yesterday I was in customer calls most of the day, three discovery sessions for the enterprise tier. Today I'm writing up the synthesis and need to finalize pricing for the Friday GTM review. I'll have a draft document in the team channel by Thursday morning so you all have a chance to weigh in. Anything else? OK, see everyone tomorrow.

**Priya Singh** _[2:32]_

Quick one — Dave, the on-call docs you updated, can you also link them in the engineering wiki? I noticed the wiki version is still pointing at the old runbook.

**Dave Kim** _[2:42]_

Good catch. I'll fix that today.

**Marcus Chen** _[2:46]_

Alright, that's it. Thanks team.
