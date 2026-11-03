---
title: "StageHand Brain Storm 1"
source: "https://chatgpt.com/c/6ae50434-b36c-83e9-9eb1-372f9b1cd559"
author:
published:
created: 2026-11-03
description:
tags:
  - "clippings"
---
blender\_domain\_ontology.yamlCode

Enjoy

#### ChatGPT said:ChatGPT

I've had a look. This is a useful starting point, and it tells me considerably more about your intended architecture. In particular, I see that you have already designed the ontology with programmatic Blender control and LLM execution guardrails in mind, rather than simply documenting Blender's object model.

Here's what stands out.

## 1\. The four-part organization

Your ontology divides the domain into four subsets:

| Subset | What it covers |
| --- | --- |
| Topology | Mesh geometry, primitive shapes, modifiers, node graphs |
| Material | Surface shaders, toon shading, line-art settings |
| Stage | Transformations, cameras, lighting, armatures |
| Pipeline | Headless execution, render passes, compositor exports |

This is a sensible separation of concerns. It also gives you a natural way to retrieve relevant portions of the ontology rather than passing the entire domain to the model.

blender\_domain\_ontology.yaml

## 2\. You have already included execution guardrails

This is particularly interesting.

For example:

- `MeshEntity` specifies that object mode must be active before applying transforms.
- `ToonMaterial` specifies a backface-culling requirement.
- `CameraRig` prohibits changing global scene scale and directs adjustments toward focal length.
- `RenderPassConfig` requires OpenEXR multilayer output to preserve certain pass information.

These are not merely descriptions of Blender concepts. They encode operational knowledge that can constrain generated code.

blender\_domain\_ontology.yaml

That is exactly the sort of information I would want available to a specialized code-generating model.

## 3\. What I notice is not yet represented

There is one important distinction.

Your current YAML defines:

- Entity classes and their inheritance.
- Attributes and their data types.
- Enumerations.
- Subsets.
- Execution rules expressed as annotations.

However, I don't yet see explicit relationships between entities or a formal representation of operations.

For example, `MeshEntity` has an `applied_modifiers` slot, but that slot contains strings rather than references to modifier entities. Likewise, there is no explicit operation class representing such actions as creating a mesh, applying a modifier, or configuring a camera.

That doesn't mean those relationships aren't available through your D4M/AA implementation. They simply aren't expressed in this LinkML file.

## 4\. What this suggests for the SLM

I would resist expanding the ontology prematurely.

Instead, I would investigate a three-part architecture:

LinkML ontology

Concepts, attributes, types, constraints and annotations

D4M / associative arrays

Relationships, retrieval, contextual subnetwork construction

Specialized SLM

Interpretation, operation selection and Blender code generation

The important question is whether D4M/AA already supplies the relationships that LinkML doesn't explicitly express, or whether those relationships are something you intend to develop.

One question I'd like to settle before proposing changes: Is this YAML a relatively complete representation of the ontology, or is it a compact LinkML schema sitting on top of a much larger D4M/AA knowledge structure?

That distinction changes my recommendation considerably. If the latter, I would want to examine the D4M representation before suggesting any changes to the ontology.

#### You said:You

LinkML is the source-of-truth. LinkML is converted into AA. Assuming the conversion is reliable, what ever is in LinkML is also in AA.

#### ChatGPT said:ChatGPT

That clarifies the architecture. I was treating LinkML and AA as potentially separate sources of knowledge. They aren't. LinkML is the authoritative ontology; AA is its operational representation.

Assuming the conversion preserves the schema faithfully, there is no reason to introduce a second knowledge representation merely to support the SLM.

This also changes how I would approach the missing relationships I mentioned.

The issue isn't whether AA contains them. If they aren't defined in LinkML, they won't be in AA either. So the question becomes whether the ontology itself has sufficient semantic coverage for the tasks you want the model to perform.

I would distinguish three capabilities:

1. Domain knowledge: What Blender entities are, their attributes, types, and constraints.
2. Operational knowledge: What operations can be performed on those entities, and under what conditions.
3. Composition knowledge: How multiple operations can be combined, ordered, and validated to achieve a requested result.

Your current YAML demonstrates meaningful coverage of the first, and some of the second through annotations. I haven't yet seen enough to assess the third.

One architectural suggestion: don't make the SLM responsible for remembering Blender's API. Let LinkML remain authoritative for the domain and its constraints, and use the SLM to translate user intent into operations grounded in that knowledge.

I would now like to examine the ontology's intended scope before suggesting additional classes or slots. Is it intended to describe Blender's domain, Blender's executable API, or both?

#### You said:You

How to proceed with ontology improvement? (1) by hand? I can use Protege to manipulate LinkML. (2) by leveraging AI resources e.g. Claude, ChatGPT, Gemini etc.

#### ChatGPT said:ChatGPT

I would use both, but not as competing approaches. My recommendation is to make ontology improvement an AI-assisted, human-governed engineering process.

You should retain control of the ontology's meaning and structure. AI should do much of the labor involved in discovering omissions, proposing relationships, examining Blender API documentation, and generating candidate LinkML changes.

There is an important distinction here: you aren't asking AI to invent an ontology. You already have one, with a defined purpose and a serialization path into D4M/AA. You're asking how to improve an existing knowledge model so that it can support a specialized code-generating SLM.

## 1\. What I would do by hand

Use manual editing for decisions that affect the ontology's conceptual integrity:

- Whether something deserves to be a class or a slot.
- Whether two concepts are genuinely related.
- Whether an operation belongs in the ontology.
- Whether a constraint is a Blender requirement or merely a preferred practice.
- Whether a proposed addition belongs in Topology, Material, Stage, or Pipeline.

These are modeling decisions, not clerical tasks.

One caution about Protégé: it is primarily an OWL ontology editor. LinkML is not OWL, and Protégé does not natively provide a complete LinkML editing environment. I would not assume that editing a LinkML ontology in Protégé is a lossless round trip.

## 2\. What I would delegate to AI

This is where I think you can gain the most leverage.

I would give an AI model three distinct jobs.

A. Ontology auditor

Give it the existing LinkML schema and ask it to identify:

- Missing Blender concepts.
- Missing attributes and relationships.
- Inconsistent naming and modeling.
- Missing constraints.
- Places where an annotation should perhaps become a formal class, slot, or constraint.

Importantly, ask it to distinguish definite omissions from possible improvements. Otherwise it will tend to expand the ontology indiscriminately.

B. Blender API researcher

Give it a defined Blender version and a specific domain, such as mesh creation or material configuration.

Ask it to examine the actual `bpy` API and identify:

- Relevant classes and properties.
- Relevant operators and methods.
- Required parameters and their types.
- Context dependencies.
- Preconditions and side effects.
- Relationships between API operations and your existing ontology concepts.

This is a particularly good use of AI because the Blender API documentation is extensive, and the work of correlating it with your ontology is laborious.

C. LinkML development assistant

Have AI propose actual YAML changes, but require it to produce a patch rather than silently rewrite the ontology.

For each proposed change, require:

1. The proposed LinkML addition or modification.
2. The reason for it.
3. The Blender API documentation or other evidence supporting it.
4. The existing concepts it relates to.
5. A test demonstrating why the change is useful.

You remain the authority approving the changes.

## 3\. Where Protégé fits

I want to qualify my earlier suggestion.

LinkML's own documentation describes YAML editing in an IDE as the normal authoring approach. It specifically recommends Protégé as a way to browse and debug an OWL rendering generated from LinkML—not as the primary LinkML authoring environment.

![](https://www.google.com/s2/favicons?domain=https://linkml.io&sz=32)

linkml documentation+1

You can generate an OWL representation using `gen-owl` and inspect it in Protégé. But OWL and LinkML have different semantics: notably, OWL uses an open-world assumption, while LinkML is generally used with closed-world schema validation. Not every LinkML feature maps directly to OWL.

![](https://www.google.com/s2/favicons?domain=https://linkml.io&sz=32)

linkml documentation+1

My recommendation:

- LinkML YAML: authoritative editing.
- VS Code or PyCharm: editing, validation, and version control.
- Protégé: visual exploration and OWL reasoning.
- D4M/AA: your operational representation.

I would not make Protégé the place where authoritative changes originate.

## 4\. The workflow I would establish

I'd make this an iterative process, with Git providing the audit trail.

1. Establish a baseline
	Preserve the current YAML as a tagged version. Generate documentation and validate the schema. Record the Blender version being targeted.
2. Define representative tasks
	Write perhaps 20–30 natural-language requests that the eventual SLM should handle.
	Examples:
	- Create a cube and bevel its edges.
	- Create a toon material with four quantization bands.
	- Set up a camera with a specified focal length.
	- Configure a headless render with normal and vector passes.
3. Have AI perform a gap analysis
	For each task, ask whether the existing ontology contains enough information to translate the request into valid Blender operations.
4. Review and incorporate proposed changes
	You approve the conceptual changes. AI prepares the LinkML patches.
5. Run the conversion and validation pipeline
	Validate LinkML, regenerate AA, and test that the conversion preserves the intended classes, slots, relationships, and constraints.
6. Test against Blender
	Have an AI-generated implementation execute in Blender. Compare the resulting scene with the intended result.

## 5\. An additional possibility: use AI to bootstrap ontology enrichment

There is actually a LinkML ecosystem project called linkml-model-enrichment intended to help bootstrap and enhance schemas. It is worth investigating, although I would not assume its automated suggestions are production-ready.

![](https://www.google.com/s2/favicons?domain=https://linkml.io&sz=32)

linkml documentation

You could also use several AI models in a review arrangement:

| Model | Assigned responsibility |
| --- | --- |
| Claude | Propose ontology extensions |
| ChatGPT | Critique modeling decisions and check consistency |
| Gemini | Research Blender API documentation and identify omissions |
| You | Approve the canonical ontology |

The important thing is that these models should not independently modify the source of truth.

## My recommendation

I would not begin by manually expanding the ontology, nor by asking an AI to make it more comprehensive.

I would begin with a set of tasks the SLM is expected to perform, and use those tasks to discover what the ontology needs.

That gives you a measurable objective: ontology improvements should increase the proportion of requested Blender tasks that can be correctly interpreted, planned, validated, and executed.

One particularly interesting consequence: your ontology can become the foundation for generating the training and evaluation data for the SLM. In other words, the ontology-development process and the model-development process can reinforce each other.

I would start with the 20–30 representative Blender tasks. They will give us a concrete basis for deciding what to add to LinkML, rather than expanding it based on abstract notions of completeness.

### This might also interest you.

![](https://images.openai.com/static-rsc-5/zRMIZU5vKyytO0GRojY6BlDJHBsVEkywTJ3TNEVxuJLga_R0qdFXNi0mYg6WmS-pKrb0EfYYrCC9DbPpaTd2bM2h-AEgLfJfrMck3pZiyx-F3xwZfG71SXCErxUvIhV1JPPRXfWlgg4RxRTlwLAAI98FlKrj6wPoSB96wTUIjsE3icIQuhkYYbs3rGKobAKOs_y_DX3w2KsMj5dJgpeQwRQS5m_N4fKpYJCBvxL_ehp1KgjUJILjoEaykygToQieEv86OoglgcAoS-eyK-TqdA)

![](data:image/webp;base64,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)

Tripo AI

Ad

Ad options

Create 3D Models with AI

Turn ideas, images, and prompts into 3D assets in one streamlined workflow.

[Learn more](https://studio.tripo3d.ai/?utm_source=openai&utm_medium=cpc&utm_campaign=cmpn_6ad78e2f95e0819e818f5e44d5f4d747&utm_adgroup=adgrp_6ad78f699790819e9dfa1db100ced908&utm_content=ad_6ae2ac42e2648196882e671555368d83&oppref=gAAAAABq6hTRJNHL_HP3LSW9ckm2q-pydej1n6XDzNTCK4dBUbVAHxntWkjSukakBV9Gj8w0sI0RPkEMjXMADwCXbgbmeBe7KbZVeKdxVBRYGWt8tnUEcOgw&olref=gAAAAABq6hTRQ0SaN6lZlWpHAcQxesjgrbWTiexUqVRb7ce1HX-ufRL4lYuR9sI9a_dKvnXPywSfsfioyAdddD3cLxyezegog1Gl9sxECP_zzTGKHpu11bxYDonIrBU5nYYOLPSblTmYXRr-rcX4jrG7StKbEwRHOww)

#### You said:You

One of the things I would like to accomplish with this SLM/Blender project is to serve as a memory supplament for the vast corpus of minutiae that proficiency in Blender requires. From my own experience, I encounter a problem. I research a solution. I finally get the solution to work. Next time I cannot remember how I did it. These solutions are often lengthy and intricate and can be sensitive to sequence. How best to remember them? (1) Save the link to the solution, (2) Save the API calls, (3) Do a video capture of what I did. All three require cataloging.

#### ChatGPT said:ChatGPT

I think you've identified a much more interesting purpose for this project than simply generating Blender Python code.

You're describing a procedural memory system: a system that remembers not just facts about Blender, but how to accomplish something that you may not need again for weeks or months.

And I think this should influence the architecture of the SLM from the outset.

Your three proposed methods each preserve something different:

| Method | What it preserves | Limitation |
| --- | --- | --- |
| Link to solution | Provenance and explanation | Link may disappear; finding the relevant passage takes work |
| API calls | Executable implementation | May omit context, ordering, and UI state |
| Video capture | Actual sequence of actions | Difficult to search, understand, and reproduce |

I wouldn't choose among these. I'd combine them into a single memory object.

## 1\. Introduce the concept of a Blender recipe

Think of a recipe as a reusable, structured record of a successful procedure.

For example, suppose you spend an afternoon figuring out how to create a particular toon-shaded material with Freestyle outlines.

The saved record might look like this:

Recipe: Create a toon-shaded object

Verified

Illustrative example, not a tested Blender procedure

Intent

Create a stylized object with discrete shading bands and outlines.

Environment

- Blender version
- Render engine
- Required scene configuration

Prerequisites

- Mesh object exists
- Camera and lighting configured
- Required render features available

Procedure

1. Create the material.
2. Configure the shader nodes.
3. Set the quantization parameters.
4. Configure outline rendering.
5. Assign the material.
6. Render and inspect.

Associated artifacts

- Original tutorial URL
- Python implementation
- Screen recording
- Screenshots of important intermediate states
- Known problems and their solutions

Verification

Expected visual result and checks for successful execution.

The important thing is that the recipe preserves the sequence and dependencies, not merely a collection of API calls.

## 2\. Make the recipe a first-class part of your ontology

I would consider introducing several concepts into your LinkML ontology:

| Class | Purpose |
| --- | --- |
| `Procedure` | A reusable solution to a task |
| `ProcedureStep` | An individual ordered action |
| `Precondition` | What must be true before execution |
| `Postcondition` | What should be true afterward |
| `Artifact` | Script, video, image, documentation |
| `Verification` | Evidence that the procedure worked |
| `Environment` | Blender version, engine, settings, dependencies |

Some particularly useful relationships would be:

- Procedure HAS\_STEP ProcedureStep
- ProcedureStep PRECEDES ProcedureStep
- Procedure REQUIRES Precondition
- Procedure PRODUCES Postcondition
- Procedure IMPLEMENTS Blender operation
- Procedure DOCUMENTED\_BY Artifact
- Procedure VERIFIED\_BY Verification

Notice that this connects procedural memory to your existing Blender domain ontology.

A procedure can reference `MeshEntity`, `ToonMaterial`, `CameraRig`, and other existing concepts. You don't need to duplicate their definitions.

## 3\. Eliminate manual cataloging through AI

This is where I think the SLM becomes particularly valuable.

Imagine a workflow:

## Capture → Understand → Remember

1\. Capture

You save a URL, Python script, screen recording, or notes.

2\. AI extraction

AI extracts the task, relevant Blender entities, ordered steps, API calls, dependencies, and verification criteria.

3\. Ontology mapping

Concepts are matched to your LinkML ontology and represented in AA.

4\. Persistent procedural memory

The recipe, artifacts, source references, and verification results are stored and indexed.

The user shouldn't have to decide whether something belongs under Materials, Topology, or Pipeline. AI should infer those relationships from the content and let you correct them when necessary.

I would also retain the original artifacts. The extracted recipe is an interpretation of the evidence, not a replacement for it.

## 4\. Retrieval is more important than cataloging

Consider what happens six months later.

You ask:

"How did I get those black outlines around the toon-shaded objects without the lines appearing on the back surfaces?"

The system should:

1. Interpret your question.
2. Retrieve relevant ontology concepts.
3. Search procedural memories associated with those concepts.
4. Find the original verified recipe.
5. Present the steps, script, and relevant video segments.
6. Explain any differences between the original environment and your current Blender version.

This is where the SLM acts as a memory interface rather than simply a code generator.

There are actually two different retrieval problems:

- Semantic retrieval: Find the procedure that addresses the problem.
- Procedural retrieval: Recover the precise sequence and conditions required to reproduce the solution.

The second is particularly important in Blender.

A vector search alone is unlikely to be sufficient. Your D4M/AA representation can provide structured relationships and dependencies, while semantic retrieval can help locate procedures based on how you describe the problem.

## 5\. A distinction I would preserve: learned knowledge versus remembered experience

I would keep two related but distinct bodies of knowledge:

A. Blender domain knowledge

What Blender entities, API functions, properties, and constraints mean.

This is your LinkML ontology.

B. Blender experiential knowledge

What you actually did to solve a particular problem, what worked, under which conditions, and what failed.

This is your procedural memory.

The distinction matters because a procedure can be valid without being the only way to accomplish something. Conversely, an API call can be documented and technically valid but still fail in a particular sequence or context.

Your system should preserve that distinction.

## 6\. What I would build first

I would resist starting with video analysis or a sophisticated RAG implementation.

Start with a minimal procedural-memory capability:

1. Save a URL, script, or manually entered solution.
2. Have an AI model convert it into a structured procedure.
3. Map the procedure to existing LinkML concepts.
4. Store the procedure and its artifacts in AA.
5. Retrieve it using natural language.
6. Allow the user to execute or inspect the recovered solution.

Then add video capture and automated extraction.

One architectural observation: This could become a major part of DoubleNaught's identity. You are developing a system that doesn't merely help someone create an SLM; it helps an SLM developer accumulate, organize, and reuse specialized knowledge.

The Blender project would be a concrete demonstration of that capability.

And I would make one design decision early: procedures should be independently versioned, identifiable, and reusable—not buried inside the model's training data. The model should retrieve and apply your accumulated experience, not absorb it irreversibly into its weights.

### This might also interest you.

![](https://images.openai.com/static-rsc-5/DLxSAnk9hyAlVcNiJawyoMvF70LlZEcvxQyysMDNpdX5HjgDtCPygczqrhb0YhUXvA00rgF5knBKV4k0Vpyd0IQJPYmT5JEiAc8tds-pmitxf4_hhrmRnwpfaCIWj6onaQCUJoQPib3hPYe6ZdBHQPTTKG6A2E6RcRrErDF7aqDDbz1eSqyWe2s9rc-QCLz16Hy34ToLWZeVr1c-kdUVxukHLnWQSydES__g-SoT7MREgNJ7qkRU6ZDeF1cMEoTn)

![](data:image/webp;base64,UklGRlgCAABXRUJQVlA4IEwCAACQEgCdASqAAIAAPlEgkEUjoiGVDzREOAUEoA1moL/oGtc8X/JL+Lfpz0/2onen8FIdF4gH7Ve63/jf2Oyy+ydfIGYAPoJozuF/LDUrXmikWVBX529ZWu/sLvNCo9/2MEE97+FJiXabV16+LBbybC2rq9O/APLi9QGDU1dCOcJ+LzCXGoBbM5MBbe87JoIdA4XahaNoMXe5Mmr0II+AAP7kiP24PPEb/DlPDlPDlMEViswE9+Uv7y+q81kSGZMcV4G0DssljSLOm4SvDy/1emfi4n7s3icyzy99A4lBuTvkOzTIi4cZt6NtpavJ71F/2TVq5UBJDJqBbLNNwEBMPkZkjIl2gimBt+E2/e/4/u31KXIznbQpxwrKdxPHzE5omeC7b6GCuhFuEj9p92Es9JsB2IHtMFIBc/lUTYZQE2B4qIHa8+GqDLO0fiprLWJ9L85/8ePFby56Bok8OxEoZht/BFcUZEy23z8pcHRX1AKGzIldQhp+wBQsJA74q2ejXtmmX8YFoHNTSIvrwrwNLLjMPxZrTN0XpMns8SnPYLPPO0tcdGpAER1+ZA8KPCewK2aiwFssvvfoem9l41MwxCg46bWDTcjPwAB8EDoOsY32564XDdhjV0Ut/W5SR/0QGnV4QuVRdQQDxisUapdC/ZTJd/3Rt+xRnah7mu/x/uwlwILW1QwIwKrlykvSydU9t/VNfJ+FWelYQcDyjnRQqk+iR/33y8fPldaml0UVRmlra1++hj8cM/GnlqQAP4m/XNSY7ntjukBZo4QAAAA=)

Baseten Labs, Inc.

Ad

Ad options

Inference finally has a textbook

Run AI models faster and cheaper. Download for free.

[Learn more](https://www.baseten.co/inference-engineering/?utm_source=chatgpt&utm_medium=paid_search_gpt&utm_campaign=education_Inference-engineering__2026-09-03&oppref=gAAAAABq6hckoADJ1-2SWTUA073MfH0TXZoCux-uqajmvZKmvjqGChu1VVL3hUjuHWIjyzeQPynKdNi_WU1lBtkx1JPXfVu7IkirmzJD7YflKMRC7aPsjrgw&olref=gAAAAABq6hckZUFMBm3g_toEPTqF2zywzoAToCD06q6ATUKXehNOmI5EC76tEHYmMAMqixURqH2Z0yXIBaWBECtGBe-YsbI2d_urAsb_aK2D28MepaVq7_XJoicsJ28fxqF9s63D6Cl36SQCUoDoU7Qcsm5Yz06QNQw)

#### You said:You

Let us look into image interpretation. I have seen existing models, given an image, describe the image verbally. If I were to do a screen capture of my Blender solution, could I leverage this capability into my SLM?

Worked for 8s

#### ChatGPT said:ChatGPT

Yes. In fact, I think screen capture could become one of the most valuable sources of training and memory data for your Blender project.

What you're describing is a way to turn visual demonstrations into procedural knowledge.

A vision-language model (VLM) can examine images and describe what it sees. Applied to Blender, it could potentially do considerably more: recognize the Blender interface, identify the operation being performed, observe changes to the scene, and help reconstruct the sequence of actions that produced the result.

There is one important distinction, though:

Describing a Blender screen is not the same as understanding the procedure being performed.

I would use a VLM as a teacher that interprets the recording, with your Blender ontology providing the vocabulary and structure needed to turn that interpretation into reusable knowledge.

## 1\. What I would capture

I would actually capture three synchronized streams of information.

![modeling - Cannot increase "Levels Viewport" from 1 to 2 on "Subdivision Surface" Modifier - Blender Stack Exchange](https://images.openai.com/static-rsc-4/N5KX-D9UbTZsDZMMKEAZJv-CM4ucaIMCwXGnPSbDTXDJq236x2cIl9hGE2aq0sq4vEsHydnLKclUlOQEUFC27VBzLgjKCE44KZiwtIixISEVqiA4nmGbQgW6CtMwWfZiR2kQWlUZg2oToKMM-JmwzzeFDFK08WmDpy1XxCMa5tM?purpose=inline)

A. Screen recording

What you see: menus, panels, property changes, viewport changes, selections, and results.

![Tutorial - Mixing a Narration With Background Music - Audacity Manual](https://images.openai.com/static-rsc-4/1UWvJo_jEaOSOtdCPqxNtTGihuAZ72sE07ZqgZaiwwvqhwJfujsy2RiC5q7c_IIoVaIIq1vFEornFQrTJglmqcQEz6dpvf2aKsN3JMWKg9I-hHTQLSTz0ItrVdADcG5knE-s_Jh9gso6bNZHaXchSMQOLZss30oirQciPi3kcOE?purpose=inline)

B. Audio narration

What you say: what you're trying to accomplish, why you're doing it, and what problems you encounter.

![ChatGPT로 이런 것도 할 수 있습니다.(Chat GPT로 3D 모델링 하는 방법) @자료실 - (사)경남인공지능ICT협회](https://images.openai.com/static-rsc-4/NPBhQYNygV2J7msQa4GAmHjCbrFCelc6J7Bk1BlIh_MJVbNJkenHBBn1mFFpQJzgtaMvlmIHUYU3kER7BdydWTCKosadum0fmmKGpoEB7pQ5gTpAuhiuxDwXxIFx945NuydcwEjf9F_v19PO_U9Qyf1LcKtJ_ioGFBfHO7q0K-A?purpose=inline)

C. Blender execution data

What Blender actually does: operator calls, relevant property changes, scene state, and resulting objects.

The third stream is particularly important. A screen recording might show you clicking a button, but it doesn't necessarily tell us which underlying API operation occurred.

For example, suppose you use a sequence of menus to configure a modifier. A VLM might recognize the modifier and its settings. But an execution log could tell us precisely which operation changed which property.

I would therefore investigate instrumenting Blender itself to record relevant operations and state changes alongside OBS recording.

## 2\. What the VLM would do

I would not ask the VLM simply to describe the video.

Instead, give it a specific assignment:

> Analyze this Blender recording as a demonstration of a technical procedure. Identify the user's objective, the sequence of operations, the relevant Blender objects and properties, the dependencies between steps, and the resulting state. Associate each step with a timestamp. Distinguish observations from inferred API operations.

Its output should be structured, something like this:

JSON

```
{
  "procedure": "Configure a bevel modifier",
  "steps": [
    {
      "sequence": 1,
      "timestamp": "00:00:12",
      "action": "Select mesh object",
      "target": "MeshEntity",
      "evidence": "Object highlighted in Outliner",
      "api_mapping": null
    },
    {
      "sequence": 2,
      "timestamp": "00:00:19",
      "action": "Add bevel modifier",
      "target": "MeshEntity",
      "api_mapping": "bpy.data.objects..."
    }
  ]
}
```

This is illustrative, not a claim that a VLM can reliably infer the exact API call from the screen alone.

The important fields are sequence, timestamp, target, evidence, and API mapping.

The VLM should be allowed to say unknown. It should not manufacture an API call to fill a gap.

## 3\. Existing models can already do much of this

There are some interesting candidates.

| Model | Relevant capability |
| --- | --- |
| Gemini | Video understanding, timestamps, audio and visual analysis |
| Qwen3-VL | Video understanding, OCR, temporal reasoning, computer-use understanding |
| Qwen3.6 | Visual understanding and video analysis |

Gemini's video interface can sample frames, process audio, and answer questions about specific timestamps. Its newer agentic video mode can selectively inspect portions of longer recordings.

![](https://www.google.com/s2/favicons?domain=https://ai.google.dev&sz=32)

Google AI for Developers+1

Qwen3-VL is particularly interesting given your interest in local models. Its stated capabilities include video understanding, improved OCR, computer-use understanding, and multimodal coding.

![](https://www.google.com/s2/favicons?domain=https://docs.qwencloud.com&sz=32)

QwenCloud+1

I would initially use a capable existing VLM as a teacher, rather than attempt to train your own vision model.

## 4\. How does this become part of your SLM?

There are two possible approaches, and I favor the first initially.

Approach A: VLM-assisted procedural memory

Screen recording + audio + Blender logs

VLM extracts structured procedure

LinkML ontology + D4M/AA

SLM retrieves and applies procedure

Approach B: Train a multimodal SLM

Train a model to accept Blender screenshots or video frames directly, associate them with operations, and generate procedures or Python code.

Approach B is possible, but substantially more demanding. It would require suitable image/video training data and a model capable of visual input.

I would not start there. Approach A gives you much of the practical benefit without requiring you to train a multimodal model.

There is another advantage: the SLM can retrieve the original video and relevant frames when it needs more information, rather than relying exclusively on a textual summary.

## 5\. A particularly useful refinement: capture the difference between states

Consider this example:

You have a mesh. You perform five operations. The mesh now has the desired geometry.

The VLM can describe what happened, but we can do better.

Capture:

- Scene state before the procedure.
- Relevant operations during the procedure.
- Scene state afterward.

Then compare the two states.

This gives us a way to distinguish the operations that actually changed the scene from incidental UI activity.

Blender's Python API provides access to its data and application structures, which makes programmatic inspection possible.

![](https://www.google.com/s2/favicons?domain=https://docs.blender.org&sz=32)

Blender Documentation

Ultimately, the system could learn that a particular sequence of operations transforms one defined scene state into another.

That is much more useful than simply remembering which buttons you clicked.

## 6\. My proposed first experiment

I would keep this very small.

Choose one Blender procedure that you've previously had difficulty remembering. Record yourself performing it, including narration. Don't worry about making a polished tutorial.

Then we can test the following:

1. Give the recording to Gemini or Qwen3-VL.
2. Have it extract a timestamped sequence of steps.
3. Compare its interpretation with the actual Blender interface and resulting scene.
4. Map the extracted concepts to your existing LinkML ontology.
5. Generate a Python implementation of the procedure.
6. Execute it in Blender and compare the result.

We can measure how much of the procedure the VLM correctly recovered, and where additional execution data was necessary.

One question that will influence the design: When you perform these Blender procedures, are you predominantly working through the graphical interface, or do you also use the Blender Python console and scripts?

I ask because if you're primarily using the GUI, I would put considerably more emphasis on visual interpretation and UI-state capture. If you use scripts as well, we can capture much more precise execution information with relatively little additional effort.

### For image/video interpretation, consider an API platform for multimodal model access.

![](https://images.openai.com/static-rsc-5/wEtT7y91Ax6MnW9s8CgjpL9SXYYiFbIg2e3YU2xyr1Hvolz5wkCtwkHgDjleSxsxbNKL0X5HOjHHxdGGhg6LtuYo-LGcFDftIm-obELxiGodckML9qYUuMAE70M03jVtPBkJ9ONDgs4DIdDHhp9CnB8qO6Po4nkBeXPVe3PA5F5_2M1TWJiX7eJ633DYNUD03LzI8LpazToKOTEbYmh6hM9sJpZOW8ziN2cY_t63P6kbNhAsoUyhUXokqqu4H_meLB0D27HwTd7eBBf4AbF9aQ)

![](data:image/webp;base64,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)

Creative Fabrica B.V.

Ad

Ad options

idea.ai API Platform

Connect to any video, image & audio model. Lowest costs

[Learn more](https://www.idea.ai/platform?campaign=cmpn_b1b81fb191ac8192a19983f11a973bfa&ad_group_id=adgrp_c5150ff6c4a0819286647b0031fc7eb6&ad_id=ad_f4afd6bfd5a081969b79a4e0f96a91fb&type=nonbrand_studio&oppref=gAAAAABq6hx2kaSe9ul8syCmxC9SWBX6ovqf6W1pjN14ZFpXQj4P3u5aGZ8gvLlczfawH8FvZDdO_GKU0kfnSYgJ04lf33Wgp8hJI73gVuHN_QtIMv8wYrow&olref=gAAAAABq6hx2ROvMzm3QkXmkrtwIUzwz_i7ao3cvOEq5YVBkJRRFgkCK_TrJ6tlDWsU6y3cLVXLkK8aEmx1-Sg9YeisVD1gMAx8Lg8ECj430EzTMxiMg3gTXYthf2XuOlsKNcCqSn_9nUFdkW7Z4O9ilZYoL3ZlV9ww)

#### You said:You

I will use DN to help create this SLM. I can see there will be another app that uses it. It will have an FE and BE et.al. It needs a name What would you suggest?

#### ChatGPT said:ChatGPT

I would give the application a name distinct from DoubleNaught. DN is the development environment that creates the SLM; this new application is the working environment in which the SLM is used.

I would also avoid a name that suggests it merely generates Blender Python. Its responsibilities are becoming broader: procedural memory, visual interpretation, workflow reconstruction, API assistance, and execution.

Here are my candidates.

## My shortlist

![Medium](https://images.openai.com/static-rsc-4/EIqGizwJJ1WENqlR_4mNkaYqgjPRifwxGglRFEnssDnjegDTG8WVgUEe4o2ictaewJCe9BMbc-ID9hruMqx-xWEzOM6Haec1M-8n_E9Q4l-Ms8HkpYDcg2MRRznLDmQNYl5xs_TKuowimTVvENmWSykZY6SksxZaJ_M-VEfVAfE?purpose=inline)

1\. SceneScribe

My favorite

A system that records, understands, remembers, and reproduces how a Blender scene was constructed.

It captures the memory aspect without limiting the application to memory.

![Training, Inspection & Maintenance](https://images.openai.com/static-rsc-4/FQX4VYv0b-MhdX1e2ly8K85J2ZXpFIjLrG1kscyWwJk6yc6d5CABUKHcAmWm_wSxxlp4PO8X6u78tifMjVRHa2TKXIuWz538u78-2n6R-UOTrGbpe7Kken1xhOn9o_eK4L89z0BlYWHGtfTNU66QvuyOMMPSGCAvDP33V3nW6zk?purpose=inline)

2\. Stagehand

A capable assistant working behind the scenes. It knows the equipment, remembers procedures, and helps execute the production.

Has a nice human quality without sounding like a chatbot.

![Arquitetura | - Angola Formativa](https://images.openai.com/static-rsc-4/eQNdONE98PFYbcCdEpsRXE_Z7blhiQbo8NYVBDHS6pFUqxezSAhIPIS8BOtLUji6yZDBCQmWz4jPR8hlWCO3cwhY0t5wdyI8WIs30YrOSj6rJNqy3Czjlwu1THjjODJQx1_j8bBEwgDutAWL9M7BTuO3AXcTFaZ-br8b0CMc3zM?purpose=inline)

3\. SceneForge

Emphasizes construction and production. Suitable if the application eventually becomes a broader scene-building environment.

![Monika Auto Components | Industrial Fabrication & Manufacturing — Ambattur, Chennai](https://images.openai.com/static-rsc-4/hFWXhcThTKpZhB6CCc1uedlSXN5_TI5-t7D-2mvb43mx4Nhwv345EHmB7-5xhG2uUTbFBWzRqyZ9wdO-BoogJAzDLtLWUOBgzVXEkRknE5yopNeIp05n9wKu2A2cEbj1KMZwAM3WpWf8JwGQpSlj9e0gtUhnaqHbusbywpArxGE?purpose=inline)

4\. Meshwright

Suggests craftsmanship and technical proficiency. Particularly appropriate for geometry, modifiers, and procedural modeling, though somewhat narrower.

![Oh noes!](https://images.openai.com/static-rsc-4/vO0nqzQjKVpjuuJMGkQaL2zC0ELpbHpcwXLHnpg0WNskopqDZu2qRDYN9RHh1R1PSoUFqshRQJiRTzmGvUH7uQWZ8E5lHTjRgEPdEXSncvpOgBOK0m8li1BmBRORnyl6q2VmwnOV45A2PN38lr-W3R0nVnDAjr4FMzjqdf3Qs78?purpose=inline)

5\. SceneKeeper

Emphasizes accumulated knowledge and the ability to recover previous solutions. Less suggestive of active scene construction.

## How I would organize the names

My preference is:

# DoubleNaught

SLM development environment

# SceneScribe

Blender application

- SceneScribe FE
- SceneScribe BE
- SceneScribe SLM
- SceneScribe Memory

I particularly like SceneScribe because it describes something more ambitious than a Blender assistant. It is a system that accumulates practical knowledge and makes that knowledge available when needed.

One naming consideration: these are conceptual candidates, not trademark or domain-availability checks. I'd check those before settling on one.

My vote is SceneScribe.