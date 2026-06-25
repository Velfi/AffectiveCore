# How the Brain's Cognition and Sense Systems Work Together

The brain is wired like a small embodied loop: cognition chooses actions, and sense systems turn those actions into observations that cognition can use on the next pass.

At the center is `src/core/brain.zig`. `BrainDeps` injects the body: camera, recognizer, image description and comparison, input, speech, speaker, memory store, graph store, system senses, chat service, autonomy planner, psyche service, image generation, email delivery, audio inspection, facial expression output, want-achievement detection, command logging, and interrupt sources. So the "mind" does not directly know how to read a camera, battery, mailbox, or microphone. It receives abstract capabilities and calls them through dependency interfaces.

## Conversation Loop

The main conversational loop is `handleConversationTurn` in `src/core/brain.zig`. It:

1. Reads user input.
2. Stores the utterance as an experience, impression, and appraisal.
3. Optionally identifies the current speaker with the camera and recognizer.
4. Builds a sectioned first-pass prompt from compact memory, user input, and observations.
5. Calls the chat service.
6. Receives JSON commands from the language mind.
7. Executes those commands.
8. Appends command results back into `observations`.
9. Repeats up to three times until the model marks the turn done, a `say` command produces speech, or an interrupt yields control.

That means cognition works by command envelopes, not direct side effects. The language mind can say "get power", use its `recognize` skill to see who it is talking to, "describe image", "recall memory", "think about this", "send email", or "say this"; then `executeChatCommands` performs the real action.

## Where Senses Enter

The sense systems enter through skills:

- `recognize` uses the camera and identity recognizer to see who the brain is talking to.
- `take_picture`, `describe_image`, and `compare_images` use the camera, image description service, and image comparison service.
- `get_time`, `get_power`, `get_storage`, and `get_database_stats` use configured system and database senses.
- `facial_expression` uses the host expression adapter when the macOS WebView body exposes one.
- `introspect` summarizes senses, capabilities, memory state, needs, autonomy state, and skills.
- Uploaded image paths are treated as visual observations through `uploadedImageObservation`.
- Uploaded audio paths are classified and, for speech or mixed audio, transcribed through `uploadedAudioObservation`.

The skill registry is explicit in `src/api/skills.zig` and re-exported through `src/api/chat_client.zig` for older call sites. Each skill has required senses or skill dependencies. For example, `recognize` needs live camera, identity recognition, and memory read/write; `get_power` needs power sensing; `dream` needs memory and image generation.

Before execution, `commandUnavailableReason` checks whether the body can actually do the command. If not, it returns a `skill_failed: <skill>: unavailable: <reason>` observation, including registry failure guidance when available, instead of pretending the action happened.

## Cognition Layers

The cognition side has a few layers:

- **Language mind**: `ChatService` chooses commands from memory, user text, and observations. Its prompt explicitly says it is a situated being with senses, memory, uncertainty, and skills.
- **Appraisal/emotion**: user speech and events are converted into impressions and appraisals, using heuristics in `src/core/emotion.zig`.
- **Memory**: sightings, summaries, appraisals, thoughts, facts, dreams, and relationship edges are stored. The first-pass prompt receives compact index context only; full memory bodies are brought in through `recall_memory`.
- **Needs**: `src/core/needs.zig` evaluates interaction, attachment, power continuity, and self-defined needs from memory, graph state, power, and autonomy energy.
- **Psyche/autonomy**: autonomous ticks build one shared psyche context from needs, memories, appraisals, impressions, relationship graph, power, energy, and skills. Id and Superego both drink from that same firehose but may assign different salience, causes, and meanings to the same stimulus: Id simulates short-term consequences, while Superego simulates long-term consequences and value continuity under uncertainty. The Ego planner reconciles those interpretations and chooses one allowed command. Camera commands are explicitly forbidden for autonomy.

## The Core Feedback Loop

```text
world/body senses
  -> observation text
  -> memory/appraisal/needs
  -> command-planning cognition
  -> command executor
  -> new sense/action result
  -> observation text
  -> cognition again
```

## Face Memory Path

The face-memory path is the more direct embodied path. A button activation calls `handleFaceMemoryActivation`: capture image, recognize identity, branch into known/unknown/uncertain handling, update person memory, sightings, and graph, then speak.

Conversation uses a softer version of the same thing: it recognizes the speaker when needed and inserts a `Current speaker recognition...` line into the chat memory context.

## Short Version

Senses are not a background stream; they are commandable skills. The brain's mind asks for observations when it needs them, the body produces structured text results, and those results become part of the next cognitive step, memory update, or spoken response.
