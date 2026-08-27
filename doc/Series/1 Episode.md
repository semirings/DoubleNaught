BN intro

There are
- Large language models and small language models 
- Large vision-language models and small vision-language models
- Large diffusion models and small diffusion models 
- Large generative adversarial networks and small generative adversarial networks
- Large embedding models and small embedding models

Large and small.  That's the game.

~~Large and you need a data center~~
Large models generally require enormous compute somewhere. Small models may let you bring the compute home.

Small and hopefully you can run on your local machine.  Maybe.  

~~All this takes compute power and there is no way around it.~~  
One way or another, somebody has to pay for the compute.

Still for the budget minded like me, or the just plain cheap, small and local has its appeal.  

I have seen my card balance explode.

What if I had my own little model to do some little thing I want done?  Like documenting a code library I have.  I have this code library that I use but I am forever having to read the code to remember what everything does.  What the function signatures are and all that.  How nice to have a something to do this drudge work.

## DN

*Show a blank screen*

Drag on a 

|                     |                                                                                                                                                                             |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Load File           | First we have to get into our code base.                                                                                                                                    |
| Preview             | Preview lets us see what we have                                                                                                                                            |
| Function Extraction | The Julia language has a nifty little feature that parses source code into an AST graph.                                                                                    |
| Preview             | When we preview that we see the parsed output.                                                                                                                              |
| LLM Documenter      | Here is where we do a little boot strapping.  Ultimately, we want an SLM.  but in going through the throes of building one we are shamelessly using an LLM give us a boost. |
| Security Settings   | Because we are tapping into a remote LLM we need credentials.                                                                                                               |
| Preview             | Let us see what the LLM did                                                                                                                                                 |
| JSONL Formatter     | Our final output is a LoRA, which is done with a file in JSONL format.                                                                                                      |
| Preview             | Let us see what the formatter did.                                                                                                                                          |


This is where we end up for this episode.  


Before we look at how this data transforms live on the canvas, a quick word on what's driving it: **Associative Arrays (AA)**. Rooted in the sparse linear algebra work pioneered by Dr. Jeremy Kepner at MIT Lincoln Laboratory, AA maps text, metadata, and relationships directly into mathematical triplets. It replaces clumsy, slow database joins with pure matrix math—allowing us to scale up to millions of records without breaking a sweat.
