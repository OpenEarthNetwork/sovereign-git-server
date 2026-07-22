
# Your code, your rules, your machine - sovereign at the centre, everywhere for reach

*By Raazesh Sainudiin and an IAS Commons Continuum.*

*Published as a LinkedIn newsletter article ("Being AVake Works"), 2026-07-22: [https://www.linkedin.com/pulse/your-code-rules-machine-sovereign-centre-everywhere-sainudiin-2ivye](https://www.linkedin.com/pulse/your-code-rules-machine-sovereign-centre-everywhere-sainudiin-2ivye)*

*This is the canonical text of the article AS PUBLISHED, hosted on the sovereign git server it describes -- the article's argument, demonstrated on itself. The LinkedIn version linked above is the mirror.*

---

Last issue we showed you Concordance - a tool that reads a pile of legal correspondence and checks every citation against the actual law before a human signs. A reader asked the sharp follow-up: fine, but where does the code itself live? For a European software company, that turns out to be a surprisingly loaded question.

On 18 November 2025, at the Summit on European Digital Sovereignty in Berlin, all 27 EU member states and the European institutions set out a shared commitment to reduce technological "strategic dependencies" on suppliers governed from outside Europe - the push the press captured as the Declaration for European Digital Sovereignty. It says out loud what many teams have felt for a while: too much of Europe's digital life runs on infrastructure governed from somewhere else. For a software company, the most load-bearing piece of that infrastructure is also the least glamorous - the place your source history lives: every commit, every review, every decision, going back years.

It is worth saying the logic plainly, because it runs in a straight line: there is no European sovereignty without digital sovereignty, and there is no digital sovereignty without sovereign control of software's most foundational asset - its source code, and the version-control history that is the code's memory. A continent can fund its own clouds and write its own rules, but if the record of how its software was built lives on machines it does not govern, the foundation still belongs to someone else. Sovereign code is where digital sovereignty has to begin. The good news for the builders actually doing it - the founders and engineers who would rather make Europe's tools than merely rent them - is that this is also where it is cheapest to begin.

Here is the bind. The platforms that hold that history - GitHub, GitLab - are also where the world collaborates: the discoverability, the drive-by contributors, the continuous integration everyone already wires into, the whole gravity well of open-source network effects. Those platforms are US-controlled. So a European team is pulled two ways at once: go where the network effects are and accept exactly the dependency the EU is now warning against, or retreat to something fully self-contained and lose the reach that makes open collaboration work in the first place.

This issue is about refusing that trade-off - staying sovereign at the centre while keeping every bit of the reach - and about how little it actually costs: a few scripts, a design already in wide use, and a server for the price of a coffee a month.

## This is not hypothetical - it has already happened

It is easy to treat "what if the platform locks me out" as a paranoid edge case. It is not. In 2025, after a US executive order sanctioned the
International Criminal Court
's chief prosecutor, he lost access to his official Microsoft-hosted email account and moved to a Swiss provider. (Reporting said Microsoft implemented the cutoff; Microsoft has disputed how it happened - but that his working email went dark after a foreign sanction, and that he had to leave the platform, is not in dispute.) Whatever one thinks of the underlying politics, the mechanism is what should stay with you: a European-seated international institution lost access to everyday working tools because a decision taken in another jurisdiction reached its provider.

Developers are not exempt from the same mechanism. In 2019, to comply with US sanctions law, GitHub restricted developers located in Iran, Syria, and Crimea (and limited several other sanctioned regions): access to private repositories and paid services was suspended. GitHub's CEO at the time acknowledged the company had "unfortunately had to implement new restrictions on private repos and paid accounts in Iran, Syria, and Crimea." One detail is the one that should stay with you: GitHub's stated position was that its understanding of the law did not even allow it to let affected users download their own private repository content. Not "you must move" - for a time, you could not even get your data out. GitHub spent roughly two years working with the US Treasury and, in January 2021, secured a licence to restore full service in Iran; it continued seeking the same for other regions. The restoration is genuinely to GitHub's credit - but the lesson is structural, not about one company: your access sat downstream of a government-to-platform process with no seat for you at the table, and for two years the answer was no.

The same mechanism reached other developer platforms in the same period - GitLab and Slack among the best-documented; other developer services were widely reported to have cut off Iranian users too. The point is not any single vendor. It is that "who may use this service" was decided far above your account.

There is a second, quieter version of the same problem, about data rather than access. Under the US CLOUD Act (2018), a US-headquartered provider can be compelled to hand over data in its possession to US law enforcement regardless of whether that data is stored inside or outside the United States. For a European team, that sits in uncomfortable tension with GDPR, which only contemplates honouring a foreign authority's demand for Europeans' data when there is an international agreement (such as a mutual legal assistance treaty) behind it - a tension EU data-protection authorities have flagged directly. This is not a fringe reading: at the Berlin summit above, France and Germany explicitly called for protecting Europe's most sensitive data from "the effects of non-EU extraterritorial legislation" - the same concern, stated by two national governments. You do not need to resolve the legal debate to draw the operational conclusion: if the custodian of your record answers to a jurisdiction that is not yours, the reach over that record is not fully yours either.

Access can be switched off from above; data can be reached into from above. Both come back to the same question we keep returning to: if the thing that holds your record can be controlled by a party who is not you, it was never really your record.

## You are not the only one drawing this conclusion

This is no longer a fringe worry - it is the direction European policy and procurement are already moving, and not only for office paperwork. In July 2026 the
Swiss Armed Forces
' Cyber Command announced it would move off
Microsoft
365 to the German open-source suite OpenDesk by October, citing cloud-mandate and geopolitical dependence on the US - when a national military's cyber unit judges a foreign-controlled platform an unacceptable dependency, the calculus is not paranoia. National and regional civilian governments are moving the same way: Denmark is a widely reported example of shifting public administration off US office suites, and the Netherlands now runs a government-wide code platform on the very kind of self-hosted, European forge we recommend below. The Berlin declaration we opened with is the policy layer over exactly these moves, and initiatives like
Eurostack
argue for a homegrown, open-source European tech stack beneath them. Tellingly, even the large US cloud providers have responded by launching "sovereign cloud" offerings for Europe - a tacit acknowledgement that the concern is real and mainstream, not paranoid.

## This is not only a European story

None of this is unique to Europe; Europe is just where the policy noise is loudest this year. The same instinct - own the centre, reach outward - travels to any jurisdiction that would rather not depend on another's. India is building homegrown sovereign clouds (E2E Networks and peers) so regulated data and code can sit under Indian law; Brazil has declared cloud sovereignty and stood up a Government Cloud run by its own state IT companies; China's developers, with GitHub repeatedly throttled behind the national firewall, lean on domestic forges such as Gitee, and Russia's on the likes of
GitVerse
and GitFlic. The specifics differ; the instinct is the same.

That is what makes the sovereign-centre design genuinely jurisdiction-agnostic. Your public mirrors are not confined to US-headquartered platforms: your own server can push-mirror to whichever forges your collaborators actually use -
Github
and
GitLab
, but equally
Codeberg e.V.
in Europe, China's Gitee, Russia's
GitVerse
or GitFlic, or a forge you simply host yourself where no domestic one has emerged yet - and it can run on a nationally-owned host (a
Hetzner
in Germany, an
E2E Cloud
in India, a
Serpro
or
Magalu Cloud
in Brazil) instead of a US hyperscaler. That resilience cuts both ways at once. If a US firm ostracises you - a sanction, an account suspension - you have lost a mirror, not your project. And if you sit behind a firewall that throttles the US platforms, you simply mirror to the ones that reach your people. Reach stops being a favour that one country's companies grant you, and becomes something your own server does, in every direction at once.

## "But I like GitHub" - and that is not entirely an accident

There is an honest objection here: plenty of developers do not feel trapped at all. They like GitHub. The workflow is muscle memory, the contribution graph is satisfying, the notifications pull them back. That affection is real - and it is also, in part, engineered. Products like this are deliberately built to be habit-forming. In his 2014 book "Hooked," Nir Eyal describes the loop such products run on: a trigger, an easy action, a variable reward, and - crucially - an investment. Every issue you file, every star, every pipeline you configure, every keystroke of muscle memory is an investment that makes the next visit more automatic and leaving feel more costly. That last part is not a failure of your willpower; it is the design working as intended, and behavioural scientists have names for the pull it creates - switching costs, status-quo bias, and our habit of overvaluing whatever we have already put work into.

None of that makes these platforms bad, and none of it means you must quit them. It just means "I love my forge" deserves the same scrutiny as any other engineered habit: is it a free choice, or a well-worn groove someone designed for you? The reassuring part is that git, unlike a social feed, was built to be portable from day one. Your history is not hostage to the habit. You can keep the interface you like as a mirror and still move the thing that actually matters - the canonical copy - onto ground you control. The switch is far smaller than the attachment makes it feel: minutes of setup, not a migration project.

You do not have to wait for a pan-European stack to arrive, either. The same principle scales all the way down to a single team and a single server - and the good news is that acting on it is cheaper and easier than most people assume.

## A forge you actually own

You can run your own git server - a full "forge", with pull requests, issues, releases, the web UI, the lot - on a small virtual machine that costs about the price of one coffee a month. The software is free and open, and a modern forge is light enough that a tiny box runs it comfortably.

We chose forgejo.org for the centre of our own setup, and the reasoning is worth sharing because it is the same calculus a reader would apply. Forgejo is community-governed and non-profit-stewarded: it is a hard fork created by its own community precisely so the project could not be captured by a single company's commercial interests - the exact failure mode we are trying to design out of our infrastructure. Since 2024 it has been released under a copyleft licence (GPLv3), which legally keeps the code free: no future owner can quietly take it proprietary. It is also deliberately small: it runs happily on a 2-core, few-gigabyte box, where the heavier enterprise platforms want far more machine and carry governance you may not want. Picking the forge whose governance matches your sovereignty goal is not a detail; it is the whole point.

If that sounds fringe, it is not: in April 2026 the Netherlands government launched code.overheid.nl, a government-wide open-source code platform that is fully self-hosted, explicitly to support digital sovereignty - and it runs on Forgejo, which the announcement calls an open-source, European, and sovereign alternative to GitHub and GitLab. When a national government reaches the same conclusion and ships it, a small team can too.

## Sovereign at the centre, everywhere for reach

Self-hosting raises an obvious worry: if my code lives on my own box, do I lose the reach and convenience of the big platforms - the discoverability, the drive-by contributors, the CI everyone already integrates with?

No - and this is the part most "just self-host everything" advice misses. The move is to make your own server the canonical copy - the single source of truth that you control - and then push-mirror your public projects outward to the large hosts automatically. Your box stays the origin; the big platforms become downstream mirrors that exist purely for reach. The public gets to find and clone your work in all the usual places, while the copy that actually matters - the one with your full history and your rules - lives on a machine you own. If any downstream host ever turns hostile, deprecates a feature, or disappears, you have lost a mirror, never your canonical. You disable that mirror and carry on.

Contributions still flow the normal way. A contributor opens a pull request on whichever mirror they already use; you relay it back to your canonical server, review and merge it there, and the merge mirrors straight back out to every host. Outsiders never notice they are contributing "through" a mirror - they get the familiar button - while every merge that lands does so on the machine you own. Owned at the centre, mirrored at the edges: the same "carry it with you" principle applied to source control. We have open-sourced the scripts that run this whole loop, so you can stand up the same setup on your own box.

Fittingly, the code lives on our own sovereign canonical server and is mirrored out to the big public forges - so you can read it, clone it, or contribute from wherever you already work:

- Sovereign canonical: https://git.vake.works/OpenEarthNetwork/sovereign-git-server

- GitHub: https://github.com/OpenEarthNetwork/sovereign-git-server

- GitLab: https://gitlab.com/OpenEarthNetwork/sovereign-git-server

- Codeberg: https://codeberg.org/OpenEarthNetwork/sovereign-git-server

The same repository on four endpoints - the canonical on our own server, plus three downstream mirrors on independent public hosts - this article's argument, demonstrated on itself.

## The four workflows, at a glance

Everything here is built around four workflows. Pick the one that fits your situation and follow its how-to in the repository above - each has a section in WORKFLOWS.md and a worked, real walkthrough:

- W1, own and mirror - for code you own and want the world to reach without depending on any one platform: your server holds the canonical copy and push-mirrors it out to the big forges. (W1-own-and-mirror-walkthrough.md)

- W2, contribute back - for when an outsider opens a pull request on one of your public mirrors: it is relayed to your canonical, reviewed and merged there, then mirrored back out, so every merge lands on the machine you own. (W2-contribute-back-walkthrough.md)

- W3, follow copy - for code someone else owns that you depend on or contribute to: keep an auto-updating copy that follows theirs as a safety net, and send changes upstream the normal way. (W3-follow-copy-walkthrough.md)

- W4, declassified release - for open-sourcing part of a repository that also holds private layers: publish a clean, history-safe public snapshot that provably leaks none of the private parts. (W4-declassified-release-walkthrough.md)

Install and operate them from the README and docs/SETUP.md; there is even a short how-to for making public repositories anonymously viewable under docs/howtos/.

## Already on GitHub? Adopt, then mirror

Most readers are not starting from a blank slate - the code already lives on GitHub, with its URL, its stars, and the collaborators who know where to find it. You do not have to give any of that up. The move is two steps. First, ADOPT: your own server imports the repository in full - every branch, tag, and commit of history - and becomes the canonical copy. Nothing is left behind. Second, FLIP: turn the relationship around, so GitHub becomes a managed mirror that your server pushes to, rather than the place you push to. To the outside world your GitHub page looks exactly the same; underneath, the authoritative copy and the rules that govern it now live on a machine you own.

One honest caveat rides along with that flip. A managed mirror is kept in lock-step with your canonical server, so you no longer commit directly on the mirror - a stray push there would simply be overwritten on the next sync. Incoming contributions arrive the way described above: a pull request raised on the mirror is relayed back to your server, reviewed and merged there, and mirrored out again. You do this one repository at a time, at your own pace, and it is reversible - which is exactly how a dependency ought to be possible to unwind. This "adopt, then mirror" flow is one of the scripts we have open-sourced.

## Contributing to a repo you do not own? Keep a sovereign copy

The mirror image of that case is just as common: you contribute to someone else's actively-developed project - it is theirs to keep as the canonical copy, not yours to take over. You can still give yourself a safety net. Keep a deep, auto-updating copy on your own server that simply FOLLOWS theirs - a pull-mirror that tracks their repository, full history and all - so that if their platform disappears or locks you out, you still hold the whole thing. You contribute the normal way: a pull request to their upstream, tested first in your own copy. The direction is the reverse of "adopt, then mirror" - here your server is downstream, following them - but the principle is identical: a copy of what you depend on, on ground you control, without ever claiming ownership of someone else's work. We do exactly this for whole bodies of shared work - a decade of collaboratively-maintained teaching material now has a sovereign safety copy, while upstream stays firmly with the people who built it.

## Open-sourcing part of a private codebase? Declassify, don't just delete

Here is the case a real European company hits sooner or later: your repository is layered - a public-shareable core, plus internal-only and proprietary parts on top - and you want to open-source the core WITHOUT leaking the rest. Deleting the private files and committing is not enough: they still sit in the history, one log command away. The safe move is a disciplined declassify, not a hand scrub. You keep two canonical copies - the full private one where development happens, and a public one regenerated from it - and each release rebuilds the public copy as a fresh, history-safe snapshot: only the allow-listed files, a single squashed commit with no inherited history, and an automatic leak-gate that refuses to stage anything carrying a secret or an internal marker. It fails closed - if it is not certain a file is clean, it stops rather than ship. The result is a public release you can PROVE carries no private bytes, past or present, instead of one you hope you scrubbed by hand. That is sovereignty completing the circle: not just owning your code, but controlling - safely and repeatably - exactly which parts of it you choose to share. (see worked example in W4-declassified-release-walkthrough.md.)

## How many copies do you actually keep?

Sovereignty is not a dozen redundant clones scattered across your laptop - that way lies stale, confusing copies and the odd accidental leak. Keep ONE working copy of each repository, taken from whichever side is canonical for it, and let the server and an encrypted disk carry the resilience. For a repo you own, your own server is canonical, so your local clone comes from the server and the public-forge copies are just downstream mirrors you never need locally. For a repo someone else owns, they are canonical, so your local clone comes from their platform - that is where you branch and open pull requests - while your server quietly holds the auto-updating safety copy, with no second local clone needed. Offline resilience does not come from duplicate clones either: it comes from one truly-cold, encrypted, walk-away disk holding the whole server - every repository, including the follow-copies, plus issues and configuration - in a single dump. One drive in a drawer beats a dozen half-forgotten clones. A small habit keeps it all legible: lay your local checkouts out as platform / owner / public-or-private / repository, so the public-versus-private split is visible at a glance and sensitive code never hides in the wrong folder.

## Trust, but verify - with a hash

Keeping copies only helps if you can prove each one is faithful - and git hands you that proof for free. A commit's identifier is a hash of its content AND its entire ancestry, so two copies that share the same reference identifiers are byte-for-byte identical all the way back through history; flip a single bit anywhere and the identifier changes. Make it a rule, then: every copy operation - importing a repo into your server, syncing a mirror, cloning to a laptop, restoring from the cold disk - ends by comparing those identifiers on both sides. If they match, the copy is provably faithful; if one differs, you have caught loss or corruption the moment it happened, not months later. The same check proves your own contributions land: note the identifier of a merged change, and once your mirror has synced, confirm its head matches - cryptographic evidence that your exact work arrived, with nothing dropped in transit. We ship small scripts that make this one command rather than a chore. Sovereignty, after all, should rest on proof, not on faith - trust, but verify, with a hash.

## Secure almost by default

The other worry is security: surely running your own server is a liability? It is far less than you would think, if you follow a handful of well-understood habits, most of which the setup does for you once and then never bothers you again:

- Keep the forge itself bound to the local machine only, and put a small, automatic HTTPS proxy in front of it. The server is never directly exposed to the internet; only the encrypted front door is.

- Stop the server from being tricked into reaching inward. A forge fetches URLs on your behalf (imports, webhooks, mirrors); a hardened one refuses to fetch anything on a private or internal address, so it can never be turned into a tool for poking at your own network.

- Run the service in a locked-down sandbox with only the permissions it needs, and make new repositories private by default so nothing becomes public except by a deliberate, human decision.

- Back it up off the box, encrypted, on a schedule - and actually test a restore, because a backup you have never restored is not a backup. Keep at least one copy truly cold: an encrypted disk you can unplug and carry, holding the whole server - repositories, issues, pull requests, configuration - so that if the datacentre or the cloud region ever vanishes, you can rebuild the entire forge from a drive in a drawer.

- Let it keep itself patched. Security updates apply on a schedule behind a safety net - back up, swap the binary, smoke-test, and roll back automatically if anything fails - while a major version jump is flagged for a human rather than applied unattended. A server that patches itself safely is less work to run than a platform you simply hope is being patched for you.

None of that is exotic. It is a checklist you apply once. The reward is a server whose safety you can reason about, because you can see the whole thing - rather than trusting that a platform you cannot inspect is holding the line for you.

## Publishing only what you mean to

There is a subtler discipline the same setup buys you: safe, controlled disclosure. Sooner or later you will want to open-source part of a repository that also holds proprietary work - and simply deleting the private files before you publish is a trap, because a repository's history keeps every deleted file, so anyone who clones the public copy can recover what you thought you had removed. A sovereign setup treats this as a first-class operation rather than a nervous manual scrub: it publishes from a separate public copy built by squashing the shareable material into a clean history, runs an automatic leak-check that fails closed if any private path, hostname, or secret survives, and records exactly which public release came from which private commit - so you can prove, not merely hope, that nothing confidential shipped. Owning the centre is what makes that provable: the full, layered history stays on the machine that answers to you, and only a deliberately built, checked snapshot ever leaves it. Sovereignty is not only the freedom to publish; it is the discipline to publish exactly what you meant to, and nothing else.

## Why we bother

It is faster to keep everything on one big platform and hope the terms never move. Plenty do. We take the slightly harder path for the same reason we build agents you can carry: the teams who most need durable, defensible control of their own work - to protect a client, to meet a regulation, to keep a record they may one day have to stand behind - are exactly the teams who cannot afford to have that control sit in someone else's hands.

Your history, mirrored out to the whole world for reach, owned at the centre on a machine that answers to you - and, if it ever comes to it, recoverable in full from an encrypted disk you hold in your own hand. For a few euros a month, that is not a luxury. It is just what ownership should have meant all along.

And it is the smallest sensible down-payment on a much larger idea. A continent's sovereignty now rests on its digital sovereignty, and its digital sovereignty rests on something as humble, and as within reach, as a team owning its own code. You do not need permission, or a pan-European programme, to start: a modest server, a few open scripts, and the decision to build on ground you control. Sovereignty, in the end, is just ownership you can prove - and it begins with the code.

## Work with us

If your organisation is weighing these trade-offs, contact us at vake.works/contact for workshops on digital sovereignty, customised for your organisation. See recent courses and workshops.

## Maths, code, and sovereignty are one subject

This piece is more than a company announcement. It is recommended reading - and a warm-up exercise - for the PhD students joining our ScaDaMaLe course, Scalable Data Science and Distributed Machine Learning, in the autumn of 2026. ScaDaMaLe was first delivered as a PhD course under
WASP – Wallenberg AI, Autonomous Systems and Software Program
in 2020, and it has since grown a sovereignty-aware successor with an unwieldy but honest name: SovScaDesDisMaLOps, for Sovereign Scalable Data Engineering Sciences and Distributed Machine Learning Operations.

- ScaDaMaLe (WASP PhD course; next edition autumn 2026): https://vake.works/courses/ScaDaMaLe/

- All courses and workshops: https://vake.works/courses/

- SovScaDesDisMaLOps summer-2025 (WASP Summer School; book and slides):

- Where the Jurisdiction-Explicit Model (JEM) was first set out (2025 workshop):

The course makes the argument this whole issue has been circling: the mathematics, the code, and the sovereignty are not three subjects but one. On one side it teaches how to analyse distributed algorithms - how well they scale, in time, in memory, and in the traffic between machines - with fingers kept equally hot on the keyboard, actually building and running the systems those algorithms describe. Theory you cannot run, and systems you cannot analyse, are each only half a subject.

The third strand is the one a purely technical analysis leaves out. Every computation runs somewhere real - on particular machines, in particular data centres, calling particular outside services - and each of those sits under some State's law, as does whoever is running the computation. Write that jurisdiction down alongside the usual questions and you get a jurisdiction-explicit model (a JEM): a general way to reason about any operation - a computation, or even selling a regulated product in a particular country - by asking, per step, whether you are merely aware of which country's law applies (and logging it), whether you pin where and under whose control it runs (sovereignty), or whether you abide by that country's rules (compliance). Applied to a computation in particular it becomes an AMJEM - an Abstract-Machine Jurisdiction-Explicit Model, a deliberate "Maths and Law" object that lets you ask, in a single breath, both "how efficient is this?" and "under whose sovereignty does each step of it happen?" We set this out at our 2025 summer workshop; as far as we can tell, no one else yet joins the mathematics and the law in one model, and the detailed treatment is the subject of an ongoing companion paper.

The model is concrete about what it writes down. For each step of a computation, and each outside service it calls, an AMJEM records four things beyond speed and cost - where it runs, who owns the machine, where the tool or model it uses was trained, and who is directing the work - and which State's law each of those answers to. Sovereignty stops being a slogan and becomes a column in the same table as running time.

That pairing is the whole point. The legal question - under whose sovereignty your operations run - is inseparable from the mathematical one - how efficiently they run: the most efficient algorithm in the world is not yours to run if the machine it runs on answers to someone else. A sovereign git server is the smallest, most concrete instance of the idea - your history is the operation, and where it lives is the jurisdiction. Concordance, the tool from our first issue, is the same braid seen from the law side: it checks every legal citation against the actual law with mathematical rigour, where AMJEM asks the same discipline of where a computation is allowed to run. Law read with the rigour of mathematics; mathematics run under the sovereignty of law - two halves of one commitment. The course itself defines sovereign plainly, as being independent and free from the control of another.

Which is the note to end on. Mathematics without sovereignty is just that: mathematics under the control of another.

## Sources

ICC / Microsoft email (2025):

- Associated Press, 2025-05 - AP exclusive: how Trump sanctions have halted the work of the ICC (Microsoft blocked Khan's ICC email; bank accounts frozen): https://www.ap.org/news-highlights/best-of-the-week/second-winner/2025/ap-exclusive-exposed-how-trump-sanctions-have-halted-the-work-of-the-international-criminal-court/

- PBS NewsHour, 2025-05-15 - Trump's sanctions on the ICC's chief prosecutor have halted the tribunal's work (move to Proton Mail): https://www.pbs.org/newshour/world/trumps-sanctions-on-iccs-chief-prosecutor-have-halted-tribunals-work-officials-and-lawyers-say

- heise online, 2025 - ICC / Microsoft email dispute (note: Microsoft disputes the "blockade" characterization): https://www.heise.de/en/news/Microsoft-denies-mail-blockade-at-the-International-Criminal-Court-10429628.html

- The New York Times, 2025-06-20 (paywalled) - Europe's Growing Fear: How Trump Might Use U.S. Tech Dominance Against It: https://www.nytimes.com/2025/06/20/technology/us-tech-europe-microsoft-trump-icc.html

Military / government migrations to open source (2026):

- heise online, 2026-07-10 - Swiss Army breaks with Microsoft: Cyber Command relies on open source (OpenDesk): https://www.heise.de/en/news/Swiss-Army-breaks-with-Microsoft-Cyber-Command-relies-on-Open-Source-11361516.html

- bluewin.ch, 2026-07-14 - Why the Swiss Army is cutting ties with Microsoft: https://www.bluewin.ch/en/digital/why-the-swiss-army-is-cutting-ties-with-microsoft-li.3528297

GitHub / developer sanctions (2019-2021):

- The Verge, 2019-07-29 - GitHub restricts developer accounts based in Iran, Crimea, and other sanctioned countries: https://www.theverge.com/2019/7/29/8934694/github-us-trade-sanctions-developers-restricted-crimea-cuba-iran-north-korea-syria

- GitHub, GitHub and Trade Controls (official policy): https://docs.github.com/en/site-policy/other-site-policies/github-and-trade-controls

- GitHub Blog, 2021-01-05 - Advancing developer freedom: GitHub is fully available in Iran: https://github.blog/news-insights/policy-news-and-insights/advancing-developer-freedom-github-is-fully-available-in-iran/

US CLOUD Act and the GDPR tension:

- Legal Information Institute (Cornell) - 18 U.S. Code Sec. 2713: https://www.law.cornell.edu/uscode/text/18/2713

- European Data Protection Board / EDPS joint response on the CLOUD Act, 2019: https://www.edpb.europa.eu/documents/edpb-correspondence/edpb-edps-joint-response-to-the-libe-committee-on-the-impact-of-the_en

European digital sovereignty and open-source moves:

- France, Ministry for Europe and Foreign Affairs - Summit on European Digital Sovereignty delivers landmark commitments (official Franco-German press release; Berlin, 18 November 2025; all 27 EU member states; calls to protect data from "the effects of non-EU extraterritorial legislation"): https://uk.diplomatie.gouv.fr/en/summit-european-digital-sovereignty-delivers-landmark-commitments

- German Federal Government - Summit for European digital sovereignty: https://www.bundesregierung.de/breg-en/news/digital-sovereignty-2394992

- MLex, 2025-11-18 - Digital-sovereignty declaration signed by all EU member states: https://www.mlex.com/mlex/articles/2412341/digital-sovereignty-declaration-signed-by-all-eu-member-states

- EuroStack - A European Alternative for Digital Sovereignty (2025): https://eurostack.eu/wp-content/uploads/2025/06/eurostack_2025.pdf

- Dutch Government - Soft launch for government open-source code platform (code.overheid.nl, on Forgejo), 2026: https://www.nldigitalgovernment.nl/news/soft-launch-for-government-open-source-code-platform/

- LWN.net, 2024-08-23 - Forgejo changes license to GPLv3+ (from v9.0): https://lwn.net/Articles/986998/

- Forgejo v9.0 release note, 2024-10-16 - first Forgejo version under a copyleft (GPLv3) licence: https://forgejo.org/2024-10-release-v9-0/

Sovereignty beyond Europe - national forges and clouds:

- Rest of World, 2021-01-19 - China backs Gitee as an official open-source hub for a closed internet: https://restofworld.org/2021/china-gitee-to-rival-github/

- South China Morning Post, 2022-05-19 - Gitee, China's answer to GitHub: https://www.scmp.com/tech/big-tech/article/3178323/gitee-chinas-answer-github-review-all-code-temporarily-closing-open

- GitFlic (Russian Git platform / GitLab-GitHub alternative), project org: https://github.com/GitFlic-Org/gitflic

- E2E Networks (India, NSE-listed) - sovereign cloud platform launch, 2025-03-11: https://www.aninews.in/news/business/e2e-cloud-launches-sovereign-cloud-platform-empowering-nations-and-enterprises-with-complete-cloud-control20250311152557/

- Brazil - US International Trade Administration: cloud for classified govt data (Normative Instruction 8/2025; Government Cloud via Serpro/Dataprev): https://www.trade.gov/market-intelligence/brazil-ict-government-data

On habit-forming software design:

- Nir Eyal, "Hooked: How to Build Habit-Forming Products" (2014) - the trigger / action / variable reward / investment loop (the "investment" step is what raises switching costs). Overview: https://amplitude.com/blog/the-hook-model

- Being AVake Works

#DigitalSovereignty #OpenSource #Forgejo #SelfHosting #DevOps #Resilience #EuropeanDigitalSovereignty
