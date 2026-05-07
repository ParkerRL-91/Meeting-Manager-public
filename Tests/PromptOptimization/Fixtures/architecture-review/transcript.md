**Lena Park** _[0:00]_

OK we're looking at the proposal Tomás put together for moving the recommendation service off the monolith. Tomás, want to walk us through the key tradeoffs?

**Tomás Reyes** _[0:12]_

Sure. The proposal is to extract the recommendation engine into its own service backed by Postgres with Redis for the hot cache. Right now it lives inside the main app, sharing the same database, and we're seeing query latency spikes whenever the marketing team runs their batch jobs against the orders table. Splitting it out gives us isolation and lets us scale the recommendation traffic independently — peak QPS for recommendations is roughly 8x what the rest of the app sees.

**Lena Park** _[0:55]_

What's the migration cost look like?

**Tomás Reyes** _[0:58]_

Three engineer-weeks for the extraction itself. Another two weeks of dual-write before we can decommission the in-monolith code path. So five weeks total, give or take.

**Aiko Tanaka** _[1:14]_

I want to push back on the Redis piece. We've already had two incidents this quarter where Redis was the failure point — once when the AWS Elasticache cluster failover took 90 seconds and pinned the API, once with a memory eviction storm. If we're adding more Redis dependency, I'd want to see a clear answer on what happens when Redis is unavailable.

**Tomás Reyes** _[1:42]_

Fair. The proposal currently has a graceful degradation path — if Redis is unreachable we serve cold from Postgres at higher latency. P99 goes from 80ms to about 400ms, which is degraded but not broken.

**Aiko Tanaka** _[2:01]_

Have we actually tested that path? Because the same thing was supposed to be true for the cart service and we found out during the last incident that the fallback hadn't been exercised in a year and didn't actually work.

**Tomás Reyes** _[2:18]_

Honest answer — no, we haven't tested it under realistic load. I'll add a chaos test as a hard prerequisite before we cut over.

**Lena Park** _[2:31]_

Good. I want that as a milestone, not a "nice to have." What about the team capacity question? We've already committed Tomás and Aiko to the billing migration through Q2.

**Tomás Reyes** _[2:48]_

The plan is to start this in Q3. Q2 stays focused on billing.

**Lena Park** _[2:55]_

OK. Aiko, you good with that timeline?

**Aiko Tanaka** _[2:58]_

Yes — assuming the chaos test gets built into the plan and we have a rollback procedure that doesn't require a maintenance window.

**Tomás Reyes** _[3:09]_

Both can be in scope. I'll update the proposal.

**Lena Park** _[3:14]_

One more thing — I noticed the proposal doesn't address what happens to the offline batch recommender. Carlos owns that and he's not here. Does extraction affect his pipeline?

**Tomás Reyes** _[3:27]_

The offline recommender hits the same Postgres tables we're moving, so yes, his pipeline would need to change. I haven't talked to Carlos yet. I'll set up a sync this week.

**Lena Park** _[3:40]_

Add it to the dependencies section. OK, I think we have alignment in principle pending the chaos test, the rollback procedure, and Carlos signing off. Let's reconvene in two weeks once those are in the doc. Tomás, can you have the updated proposal ready by next Friday?

**Tomás Reyes** _[4:01]_

Yes, by next Friday.

**Lena Park** _[4:04]_

Great. Thanks both.
