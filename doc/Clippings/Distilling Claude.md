---
title: "Distilling Claude"
source: "https://chatgpt.com/c/6a6a015b-cc00-83ea-92ce-d1c57dcb7f17"
author:
published:
created: 2026-07-31
description: "ChatGPT conversation with 5 messages"
tags:
  - "clippings"
---
Claude can generate calls to the Blender API. It is expensive. How would it go to distill an SLM from Claude to run locally?

  

#### ChatGPT said:

Thought for 4s

Yes. **That is an excellent candidate for distillation**, and in fact it is a much cleaner distillation problem than trying to reproduce "Claude" generally.

You don't want to distill Claude.

You want to distill **one particular capability of Claude**:

> **natural-language video/scene instructions → correct Blender Python/API operations**

That changes the problem enormously.

### Think of Claude as the teacher

Suppose you give Claude:

> Create a 10-second shot of a small wooden cabin in a snowy forest. Camera starts outside, moves toward the window, and ends looking into the lit interior.

Claude might produce a fairly complicated Blender Python program.

You save the useful pair:

```
INPUT:
Create a 10-second shot of a small wooden cabin...

OUTPUT:
import bpy
...
```

Do this thousands of times, preferably with variations and difficulty levels.

You now have:

```
Natural-language task
        ↓
      Claude
        ↓
Blender Python program
        ↓
  Blender execution
        ↓
   Success / failure
```

The **execution result is extraordinarily valuable**. You don't merely want Claude's answer. You want to know whether the resulting program actually worked.

### The real training set

I would make each training example richer than ordinary instruction tuning:

```
{
  "request": "Create a red chair...",
  "blender_code": "...",
  "execution": {
    "success": true,
    "errors": []
  },
  "scene_summary": "...",
  "operations": [
    "create_mesh",
    "assign_material",
    "position_object",
    "set_camera"
  ]
}
```

Now you can train an SLM to produce Blender operations rather than merely imitate Claude's prose.

That distinction is important.

### And you can make the student considerably smaller

You might discover that Claude's Blender response contains a great deal of material that your SLM doesn't actually need.

For example:

```
Claude:
explanation
reasoning
warnings
Blender code
comments
explanation of Blender code
```

Your SLM might need only:

```
structured task → Blender program
```

Recent distillation research supports exactly this general strategy: a larger model can provide supervision while a much smaller student learns the task behavior, and synthetic teacher-generated data can be surprisingly effective. [![](https://www.google.com/s2/favicons?domain=https://arxiv.org&sz=128)arXiv+1](https://arxiv.org/abs/2410.18588?utm_source=chatgpt.com)

### I would actually go one step beyond simple distillation

Instead of training:

```
Prompt → Python
```

I would train:

```
Prompt
  ↓
Scene Plan
  ↓
Blender Operations
  ↓
Python
```

For example:

```
PROMPT
"Make a medieval stone tower at sunset."

        ↓

SCENE PLAN
objects:
  tower
  ground
lighting:
  sunset
camera:
  low-angle

        ↓

OPERATIONS
create_cylinder
create_stone_material
create_ground
create_sun
create_camera
set_camera_target

        ↓

BLENDER PYTHON
...
```

That intermediate representation becomes a **compact semantic language for Blender**.

And this is where your DoubleNaught idea gets interesting.

You don't necessarily want an SLM that knows *all of Python*. You want one that knows a **restricted vocabulary of Blender operations** extremely well.

### Then the local model becomes tiny

Imagine your SLM has learned:

```
CREATE_OBJECT
MOVE
ROTATE
SCALE
MATERIAL
LIGHT
CAMERA
ANIMATION
MODIFIER
BOOLEAN
TEXTURE
RENDER
```

It can emit structured operations, which a deterministic Blender backend converts to Python.

That gives you:

```
User
  │
  ▼
Local SLM
  │
  ▼
Scene DSL / AA
  │
  ▼
Blender executor
  │
  ▼
Scene
```

That is **much more attractive to me than trying to make a small model write arbitrary Blender Python.**

### And D4M fits beautifully here

This is where your D4M interest suddenly becomes practical.

The scene itself could be represented as an associative structure:

```
Object      Attribute       Value
------------------------------------------------
cabin       type            structure
cabin       material        wood
cabin       location        (0,0,0)
window      part_of         cabin
window      material        glass
camera      target          window
sun         direction       ...
```

The SLM doesn't have to reconstruct an entire scene from prose every time.

It modifies a structured world representation.

Then Blender becomes the renderer.

That gives you a very interesting architecture:

```
┌─────────────┐
             │  Local SLM  │
             └──────┬──────┘
                    │
              scene operations
                    │
                    ▼
             ┌─────────────┐
             │     D4M     │
             │ scene model │
             └──────┬──────┘
                    │
               transformation
                    │
                    ▼
             ┌─────────────┐
             │   Blender   │
             └─────────────┘
```

And **this is exactly the kind of specialized SLM pipeline you've been talking about**: the expensive general-purpose model does the initial teaching; the local models subsequently do the repetitive specialized work.

### There is one very important caveat

You cannot simply take Claude's internal weights or hidden knowledge and "distill Claude" directly. The practical route is **behavioral distillation through examples**: use Claude as a teacher to generate training examples, then train your own student model on those examples. Anthropic itself describes distillation as training a less capable model on outputs from a stronger model. [![](https://www.google.com/s2/favicons?domain=https://www.anthropic.com&sz=128)Anthropic](https://www.anthropic.com/news/detecting-and-preventing-distillation-attacks?utm_source=chatgpt.com)

And before building a large corpus from Claude outputs, you'd want to check the current terms applicable to the particular Claude/API access you're using.

### The economics could be compelling

Suppose Claude costs you substantial money every time it has to reason through a Blender task.

You use Claude **10,000 times** to create a carefully filtered training corpus.

Then your local model handles:

```
10,000,000
```

subsequent Blender instructions locally.

That's the fundamental economic argument for distillation.

And there is an even better possibility:

**Use Claude only where the local model fails.**

So the pipeline becomes:

```
User request
     │
     ▼
Local Blender SLM
     │
     ├── confident → execute locally
     │
     └── uncertain
             │
             ▼
           Claude
             │
             ▼
       validated solution
             │
             ▼
       training corpus
             │
             ▼
        improve SLM
```

Now Claude isn't your expensive runtime dependency. **Claude becomes the teacher that progressively makes the local model less dependent on Claude.**

That, to me, is a particularly strong DoubleNaught use case.