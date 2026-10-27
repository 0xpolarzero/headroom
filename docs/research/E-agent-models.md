# Delegation models: evidence and descriptions

As of **2026-10-27**. **V** = vendor statement/evaluation; **T** = independent third-party measurement; **I** = inference. Roles are user-selected routing policy. In particular, “not for” below excludes a delegation role; it does not assert model incapability. Public API results do not establish performance through Codex, Antigravity, or the configured MCP tool.

**Specifications and cost**

All models output text. Prices are standard API USD per million uncached input/output tokens, not subscription charges. Undated documentation and live leaderboards were checked on 2026-10-27.

| Model | Vendor context limit; inputs | Input/output price; tier |
| --- | --- | --- |
| GPT-6.1 Sol | 1,050,000; text, image | $2/$10; balanced. [V catalog](https://developers.openai.com/api/docs/models) |
| GPT-6.1 Terra | 1,050,000; text, image | $1/$5; efficient. [V model page](https://developers.openai.com/api/docs/models/gpt-6.1-terra) |
| GLM-5.3-Flash | 1M; text, image, video, files | $0.15/$0.50; budget. [V specifications](https://docs.z.ai/guides/vlm/glm-5.3-flash), [pricing](https://docs.z.ai/guides/overview/pricing) |
| Gemini 3.8 Flash | 1,048,576 input; text, image, video, audio, PDF | $0.75/$3.75; budget. [V API docs, updated October 22](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash) |
| Gemini 4 Argon | 1,048,576 unified input/output; text, image, video, audio, PDF | $2/$10; flagship. [V API docs, updated October 14](https://ai.google.dev/gemini-api/docs/models/gemini-4-argon) |
| GPT-6 Astra | 1,050,000; text, image | $10/$50; premium. [V catalog](https://developers.openai.com/api/docs/models) |
| GPT-6 Luna | 1,050,000; text, image | $0.10/$0.50; lowest OpenAI tier. [V catalog](https://developers.openai.com/api/docs/models) |
| GLM-5.3 | 1M; text only | $1.40/$4.40; GLM flagship. [V specifications](https://docs.z.ai/guides/llm/glm-5.3), [pricing](https://docs.z.ai/guides/overview/pricing) |

Google’s introductory prices double for Argon on December 1, 2026, and Flash on January 1, 2027. [V pricing](https://ai.google.dev/gemini-api/docs/pricing). OpenAI’s listed rates apply through 272K input; longer prompts increase input/cache rates 2× and output 1.5×. [V Terra pricing](https://developers.openai.com/api/docs/models/gpt-6.1-terra).

**Positioning and role fit**

- **sol, high:** V: near-Astra agentic coding, computer use, and professional work at one-fifth Astra’s token prices; released September 29. [Announcement](https://openai.com/index/introducing-gpt-6-1-sol/), [dated changelog](https://developers.openai.com/api/docs/changelog). OpenAI’s October 14 maintenance study found Sol Ultra produced 131 accepted findings versus Astra Ultra’s 142, but missed dependent feature flags. This is audit evidence, not a high-effort review benchmark. **I:** supports the review role; no direct plan/diff-review comparison found. [Study](https://developers.openai.com/blog/maintaining-software-with-the-gpt-6-family).
- **terra-cu, low:** V: visual reasoning, precise computer use, and writing; launched October 26. OpenAI reports Agents’ Last Exam parity with Astra at medium effort, and task completion over three times faster than Sol/Astra. It recommends Sol/Astra for the hardest coding. **I:** strong fit for the GUI-only role; speed/parity claims do not establish low-effort macOS-MCP performance. [Announcement](https://openai.com/index/introducing-gpt-6-1-terra/), [dated release notes](https://help.openai.com/en/articles/9624314-model-release-notes).
- **flash:** V, August 26: inexpensive multimodal coding, browser/GUI workflows, and general professional tasks. Coding Plan supplies three times GLM-5.3’s quota; thinking cannot be disabled. The advertised 200 tokens/s belongs to **FlashX**, which is excluded from Coding Plan. **I:** good budget worker fit; “Flash” alone does not prove low latency. [Announcement](https://z.ai/blog/glm-5.3-flash), [current documentation](https://docs.z.ai/guides/vlm/glm-5.3-flash).
- **gemini, low:** V, September 2: long-horizon software engineering, autonomous agents, and enterprise work. Lower effort reduces token overhead; high-effort tasks can consume extra tokens. **I:** good worker fit, with native audio input beyond GLM Flash’s documented modalities; no demonstrated speed advantage over GLM Flash on these subscription routes. [Announcement](https://blog.google/innovation-and-ai/models-and-research/gemini-models/3-8-flash-and-3-8-flash-cyber/), [API specifications](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash).
- **argon, high:** V, October 13: frontier reasoning for complex engineering, knowledge work, science, and autonomous agents. **I:** reasoning supports the advisor assignment, but no benchmark establishes superior opinions, trade-off judgments, or recommendations. Its coding results are mixed against Astra, not uniformly stronger. [Model card](https://deepmind.google/models/model-cards/gemini-4-argon/).

**Benchmark evidence**

Percentages below retain benchmark versions. Different harnesses, efforts, subsets, and dates prevent a single ranking. Vendor launch results are not measurements of all five configured agents.

| Model; evidence date/type | Coding and agentic | Computer use; long context |
| --- | --- | --- |
| Sol high; October 27 T snapshot | Terminal-Bench 4.0 **52%**; AutomationBench-AA **64%** | AA-LCR v1.1 **82%**. [T comparison](https://artificialanalysis.ai/models/comparisons/gpt-6-1-sol-high-vs-gpt-6-sol-high). V: max OSWorld 2.0 within **2.1 points** of Astra. [Launch](https://openai.com/index/introducing-gpt-6-1-sol/) |
| Terra; October 26 V | Terminal-Bench 4.0 **50.3% at max** | OSWorld 2.1 offline: medium surpasses predecessor’s best; absolute score unavailable in retrieved text. [Announcement](https://openai.com/index/introducing-gpt-6-1-terra/) |
| GLM Flash; August 26 V | DeepSWE v1.1 **63.4%**; Terminal-Bench 2.1 **84.3%**; Toolathlon Verified **78.4%** | OSWorld 2.0 **59.1%**. [Launch evaluation](https://z.ai/blog/glm-5.3-flash?trk=article-ssr-frontend-pulse_little-text-block) |
| Gemini Flash; September 2 V | DeepSWE v1.1 **73.7%**; Terminal-Bench 4.0 **19.1%** | OSWorld 2.0 **59.0%**, partial score, batch tool enabled. Not established at low thinking. [Card](https://deepmind.google/models/model-cards/gemini-3-8-flash/) |
| Argon; October 13 V | DeepSWE v1.1 **77.9%**; Terminal-Bench 4.0 **57.4%** | OSWorld 2.0 offline partial **69.2%**; GraphWalks BFS F1, 256K–1M: **84.2%**. [Card](https://deepmind.google/models/model-cards/gemini-4-argon/) |
| Astra; October 13 Google-reported V comparison | DeepSWE **74.1%**; Terminal-Bench 4.0 **58.2%** | Same OSWorld **72.6%**; GraphWalks range **71.8%**. [Comparison](https://deepmind.google/models/gemini/) |
| GLM-5.3; August 14 V | DeepSWE **66.9%**; Terminal-Bench 3.0 **28.3%**; Toolathlon **73.0%** | Agents’ Last Exam **28.5% is CLI**, not desktop evidence. [Launch](https://z.ai/blog/glm-5.3) |

T: Artificial Analysis’s October 27 live snapshots show Sol high approximately **60 tokens/s**, Terra low **91**, GLM Flash **68.9**; Gemini low speed is unavailable. These API generation rates exclude whole-task overhead and do not measure the configured routes. [Sol](https://artificialanalysis.ai/models/gpt-6-1-sol-high/), [Terra](https://artificialanalysis.ai/models/releases/gpt-6-1-terra), [GLM](https://artificialanalysis.ai/models/glm-5-3-flash/), [Gemini](https://artificialanalysis.ai/models/gemini-3-8-flash-low).

Contrast: V positions Astra for demanding reasoning and Luna for focused high-volume work. Luna launched September 22. [Guide](https://developers.openai.com/api/docs/guides/latest-model), [changelog](https://developers.openai.com/api/docs/changelog). No Luna task scores, comparable Argon latency, or standalone long-context scores for Terra/GLM Flash/GLM-5.3/Gemini low were established here.

**Routing and remaining evidence**

I: separate advice, review, execution, and GUI operation by user intent. Between workers, price/quota favors GLM Flash; both support images and approximately 1M context, so neither distinguishes them. Gemini adds native audio. Actual endpoint modality forwarding, effective context, task cost, and macOS reliability remain unverified. Antigravity offers Flash on free plans and Argon on paid Pro/Ultra; API prices do not describe those quotas. [V availability](https://antigravity.google/docs/models).

Action: compare both workers on the same implementation task and Terra low on one representative macOS workflow.

**Proposed descriptions**

Capabilities trace to the positioning sources above; exclusions express the selected roles.

- **argon:** Advisor: use for requested opinions, trade-offs, and recommendations needing deep reasoning; not for implementation, code review, or macOS app operation.
- **sol:** Reviews: use for code, plans, and diffs needing strong coding reasoning; not for implementation, general advice, or macOS app operation.
- **flash:** Implementation and exploration: use for inexpensive general delegated work when Claude limits are low; not for advice, reviews, or macOS app operation.
- **gemini:** Implementation and exploration: use for inexpensive general work at low thinking when Claude limits are low; not for advice, reviews, or macOS app operation.
- **terra-cu:** Computer use only: use for operating macOS app windows through the MCP tool, backed by visual reasoning and computer-use capabilities; not for coding, reviews, or advice.
