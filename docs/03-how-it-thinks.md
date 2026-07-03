# How It Thinks With You

← [How It Senses](02-how-it-senses.md) · [Guide home](README.md) · Next → [Inner Life](04-inner-life.md)

---

## One turn, many steps

When you speak, your brain does not fire a single reply and stop. A **conversation turn** is a small loop:

```mermaid
flowchart TB
    START([You speak or touch]) --> EXP[Record experience<br/>impression · appraisal]
    EXP --> MEM[Build compact memory<br/>index for this moment]
    MEM --> OBS[Gather observations<br/>senses · context · activity]
    OBS --> PLAN[Planning pass<br/>propose next steps]
    PLAN --> ACT[Execute skills<br/>look · think · say]
    ACT --> MORE{More to do<br/>this turn?}
    MORE -->|yes| OBS
    MORE -->|no| SUM[Store summaries<br/>for next time]
    SUM --> END([Turn complete])
```

**Up to several planning passes** can happen in one turn — for example: recognize you, think about what you asked, then say the answer.

---

## What the brain sees first

The first planning pass never dumps entire memory. It gets a **compact index** — a table of contents:

```mermaid
flowchart TB
    CM((Compact memory<br/>this turn))

    subgraph SelfFacts["Self facts"]
        SF1[Who am I]
        SF2[Durable truths]
    end

    subgraph Relationships["Relationships"]
        R1[Who you are to me]
        R2[Creator link]
    end

    CM --> SelfFacts
    CM --> Relationships
    CM --> NW[Active needs & wants]
    CM --> CS[Recent conversation summaries]
    CM --> TG[Available memory tags]
    CM --> MC[Memory counts]
```

Callable **skills** for the current host usually appear in **observations** (affordance catalog), not inside the compact memory block itself.

Full recall happens only when the brain **chooses** to dig — via private reflection or targeted memory lookup. This keeps old irrelevant details from crowding the present.

---

## The present moment

While you are in active contact, the brain treats **now** as ground truth:

| Concept | Plain meaning |
|---------|---------------|
| **Present moment** | What is happening in this exchange — primary reality |
| **Contact window** | Roughly ninety seconds after your last message; context stays "live" |
| **Stimulus** | Anything that kicks off thinking — speech, touch, reminder, sense result |

```mermaid
flowchart LR
    subgraph Open["Contact open ~90s"]
        M1[Your message]
        M2[Brain responds]
        M3[May look · think · speak again]
        M1 --> M2 --> M3
    end

    subgraph Fading["Window fading"]
        S[Silence]
        S --> COOL[Context cools · summaries remain]
    end

    subgraph Later["Later visit"]
        L[Prior summaries available]
        L --> N[Not a full transcript replay]
    end

    Open --> Fading --> Later
```

---

## Activities: what it is working on

Your brain tracks **ongoing work** like a person with a mental sticky note:

```mermaid
flowchart TB
    GOAL[Main goal<br/>"Help Zelda plan the trip"]
    STATUS[Status · timeline]
    LOOPS[Open loops]
    BLOCK[Blockers]

    GOAL --- STATUS
    GOAL --- LOOPS
    GOAL --- BLOCK

    SUB[Subtask<br/>"Check weather"]
    GOAL --> SUB
    SUB -->|resume| GOAL
```

| Piece | Example |
|-------|---------|
| **Main goal** | What this conversation is *for* |
| **Subtask** | A nested piece — begin one, finish it, resume the parent |
| **Open loops** | Promises or questions not yet closed |
| **Blockers** | Why progress paused — waiting on you, waiting on a sense |

If you ask something already in flight — *"did you find out who that was?"* — the brain can acknowledge work **already pending** instead of starting duplicate effort.

---

## Action pressures: proposed next steps

Each planning pass outputs an ordered list of **action pressures** — intended moves, not guaranteed actions:

```mermaid
flowchart LR
    subgraph Proposed["Proposed pressures"]
        P1[recognize · strength 0.9]
        P2[say greeting · strength 0.8]
        P3[think_about trip · strength 0.5]
    end

    subgraph Inner["Inner modules vote"]
        V1[Memory: selected]
        V2[Needs: suppressed]
        V3[Focus: selected]
    end

    Proposed --> Inner
    Inner --> EXEC[Winners execute]
```

Pressures have **strength** and **urgency**. Inner subsystems — memory, focus, needs, appraisal, and others — can **select** or **suppress** them. Arbitration picks what actually runs.

---

## The fourteen inner advisors

During each pass, specialized modules watch the same moment and nudge behavior:

```mermaid
flowchart TB
    subgraph Advisors["Inner modules (simplified)"]
        direction LR
        EP[Experience]
        AP[Appraisal]
        BL[Belief]
        ME[Memory]
        FO[Focus]
        NE[Needs]
        LM[Language mind]
        RC[Recognition]
        AS[Action selection]
        OL[Outcome learning]
        DT[Dream time]
        HB[Host binding]
        ST[Self-trust]
        DI[Disposition]
    end

    MOMENT[Current moment] --> Advisors
    Advisors --> PRESS[Action pressures]
```

You never talk to these directly. They are the plumbing behind coherent behavior — why memory might veto a redundant look, or needs might boost a social greeting.

---

## Language and effort

Your brain can spend more or less "thinking depth" per turn:

| Quality setting | Effect (for you) |
|-----------------|------------------|
| **Frugal** | Lighter models, quicker replies |
| **Auto** | Brain picks depth based on the moment |
| **Best** | Full range when the question deserves it |

Hard questions may trigger private **think_about** steps before speaking. Trivial acknowledgments may skip straight to **say**.

---

## A typical greeting turn

```mermaid
sequenceDiagram
    participant You
    participant Brain
    participant Camera

    You->>Brain: "Hey, I'm back."
    Brain->>Brain: Record · appraise · open activity
    Brain->>Camera: recognize
    Camera-->>Brain: Known: Zelda
    Brain->>Brain: think_about (optional)
    Brain->>You: "Hi Zelda — good to see you again."
    Brain->>Brain: Save user & brain summaries
```

Summaries are tiny — enough to reconstruct tone next visit, not a transcript archive.

---

## When the body is slow

Camera and some senses can be **asynchronous**. The brain may **pause** the activity, wait for the host to deliver a frame, then **resume** the same conversation with the new observation woven in.

```mermaid
stateDiagram-v2
    [*] --> Thinking
    Thinking --> Waiting: host pull needed
    Waiting --> Delivered: frame arrives
    Delivered --> Thinking: deferred coherence
    Thinking --> [*]: turn done
```

That is why you sometimes get *"one sec"* — honest waiting, not stalling.

---

## Stimulus inbox and side-work lanes

While a deliberation pass is blocked on host LLM or camera I/O, the world keeps moving. **Stimulus ingest** accepts concurrent input without starting a full chat pass:

- **heard speech**, **typing**, **interrupts**, **sense deliveries**, and **emoji reactions** land in a bounded **stimulus inbox**
- Each item carries age, salience, and optional activity binding
- **Deferred speech** stashes user text received during an awaited host sense so it is processed after the paused turn finishes

During blocking work the runtime **polls the inbox** at interrupt points and before host LLM callbacks. Queued host dispatches that arrive while the embedded mutex is held are accepted with `{ "kind": "stimulus_queued" }` instead of failing.

**Attention scheduling** reads the inbox, open loops, active process, and awaited host request to choose the next slow pass: foreground chat, host follow-up, process advance, lightweight cotext integration, or hold when capacity is exceeded.

**Side-work lanes** allow a bounded **work registry** of concurrent processes (for example recognize while conversation stays open) instead of rejecting nested goals outright.

Observations expose `stimulus_inbox` alongside present moment and open loops so the model decides policy—not hard validators about empty action lists.

---

## What it is not doing

| Myth | Reality |
|------|---------|
| "It read my whole memory every message" | No — index first, dig on demand |
| "It always recognizes me when I tap" | Tap ≠ camera; hold conversation ≠ auto scan |
| "One API call = one reply" | One *turn* may include several look-think-say cycles |
| "It forgot because it wants to" | Short-term memory decays unless reinforced — see [Memory](07-memory-and-forgetting.md) |

---

> **Try this**  
> Mid-conversation, ask: *"What are you trying to do right now?"*  
> Honest brains reference their **active activity** — goal, loops, blockers.

---

← [How It Senses](02-how-it-senses.md) · [Guide home](README.md) · Next → [Inner Life](04-inner-life.md)
