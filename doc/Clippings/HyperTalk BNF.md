---
title: "HyperTalk BNF"
source: "http://www.jaedworks.com/hypercard/scripts/hypertalk-bnf.html"
author:
  - "[[Jeanne A. E. DeVoto]]"
published:
created: 2026-11-04
description: "Formal BNF description of the HyperTalk language (versions 1.2.5 and 2.2)."
tags:
  - "clippings"
---
## Syntax Symbols

The following is a list of syntactic symbols and terms you must know for the rest of this material to make sense:

### Special Symbols

`< >`

Angle brackets enclose a general term (as in` <card>`). This *nonterminal* (as the general term is formally called) is replaced by a specific instance of that term. For example, in the syntactic statement go \<card>, you can replace`  <card>  `with any valid form of a card reference -` go card 7`,` go back`, and so on. The section on [Syntactic Terms](#syntactic-terms) is a complete list of all the non-obvious terms that might appear within angle brackets.

`|`

A vertical bar separates mutually exclusive options. For example, the syntactic statement`  go { help | home | back }  ` means that it's legal to say`  go help  ` or`  go home  ` or`  go back  ` (but you can't say`  go help home  ` or` go home back`).

`[ ]`

Square brackets enclose optional elements that you can use or ignore. For example, the syntactic statement`  go [to] <card>  ` means that legal forms for the **go** command include`  go <card>  ` and` go to <card>`.

`{ }`

Curly braces enclose a group of related terms. Curly braces are often used to indicate precedence of consideration. For example, part of the syntax for backgrounds is` background {id <unsigned> | <endLine> | <expr> | <token>}`. The braces indicate that HyperCard first looks for the word`  ID  ` (to indicate an ID number); if it can't find one, it looks to see if the next character after the word`  background  ` is an end-of-line marker; and so it goes.

`@`

The At sign (used only in the [formal syntax definition of HyperTalk 1.2](#1.2.5-syntax)) means that the syntax treats expressions as expandable - an expression that yields text in the proper syntactical form is as acceptable as text that already appears in the proper syntactical form. (An expression is any value or any group of values, sources of value, and operators meant to be taken as a single whole.)

For example, the formal syntax for the **click** command is  
`     click at {<integer>, <integer>}@`  
The following statement already appears in the proper syntactical form:  
`     click at 100, 300`  
The statement  
`     click at field 1`  
also works if field 1 contains a value that matches the required syntax for **click** - a pair of integers separated by a comma.

If`  @  ` appears before the phrase, HyperTalk tries to evaluate the phrase as an expression before it tries to evaluate the phrase as a literal (that is, a group of characters to be taken for their actual face value). This process applies only to stacks. If`  @  ` appears after the phrase (as it does in the example), HyperTalk tries to evaluate the phrase as a literal before it tries to evaluate the phrase as an expression.

### Syntactic terms

`<bkgnd> ` is any valid background reference.

`<button> ` is any valid button reference.

`<card> ` is any valid card reference.

`<empty> ` is the null string.

`<endLine> ` is the end of line character (ASCII 13).

`<expr> ` is any expression - value, source of value, or group of values - meant to be resolved and taken as a single value. Expressions are covered in detail in Chapter 9 of [HyperTalk 2.2: The Book](../HT2-2TB/index.html).

`<factor> ` is the first fully resolvable portion of an expression. Factors are covered in detail in Chapter 9 of [HyperTalk 2.2: The Book](../HT2-2TB/index.html).

`<field> ` is any valid field reference.

`<line> ` is everything remaining in a line up to the end of the line or a comment.

`<numericFactor> ` is a factor that can be converted to a number.

`<object> ` is any object.

`<ordinal> ` is one of the ordinal numbers`  first  ` through` tenth`, plus the special ordinals` last`,`middle ` (or` mid`), and` any`. (If the something that`  middle  ` is in has an even number of units, then`  middle  ` moves toward the high end. So the middle of 6 is 4.)

`<return> ` is the return character, entered by pressing the Return key or appended within a script by the vocabulary word **return** or the expression` numToChar(13)`.

`<stack> ` is any valid stack reference.

`<token> ` is a single word without quotation marks meant to be taken literally.

`<unsigned> ` is any expression that can be converted to an integer whose value is zero or greater.

The adjectives` this`,` prev`, and`  next  ` refer only to cards and backgrounds in the current stack.

All words that are not within angle brackets must appear in a reference exactly as they appear in the given syntax examples. So in the phrase`   <ordinal> card  ` the word`  ordinal  ` is replaced with one of the ordinal numbers (`  first  `,`  second  `,`  third  `...), but the word`  card  ` (or its legal synonym` cd`) must appear as in the example.

### Synonyms

Here's a list of legal synonyms for objects, tools, and containers:

  bg            bkgnd          background
  bgs           bkgnds         backgrounds
  button        btn
  buttons       btns
  card          cd
  cards         cds
  char          character
  chars         characters
  commandChar   cmdChar
  fields        flds
  fld           field
  gray          grey
  menuMessage   menuMsg
  msg           message
  pict          picture
  poly          polygon
  prev          previous
  reg           regular

So, for example, wherever you see syntax that uses the word "bg", you could instead use either "background" or "bkgnd" and get the same results.

---

## Formal Syntax of HyperTalk version 1.2.5

This section describes the One True Syntax for the HyperTalk scripting language on the Macintosh, HyperCard versions through 1.2.5. It shows precisely what's allowed in every construct. It uses the syntax symbols listed in the [Syntax Symbols section](#syntax-symbols).

### Scripts

\<script> = \<script> \<handler> | \<handler>

\<handler> =
  on \<messageKey> \<return>
    \<stmntList>
  end \<messageKey> \<return>

\<stmntList> = \<stmnt> | \<stmntList> \<stmnt>

\<stmnt> = {\<messageSend> | \<keywordStmnt> | \<empty>} \<return>

\<keywordStmnt> =
  do \<expr> |
  exit repeat | exit \<messageKey> | exit to HyperCard |
  global \<identList> |
  next repeat |
  pass \<messageKey> |
  return \<expr> |
  send {\<expr> | \<token>} \[ to \<object> \] |
  \<ifBlock> | \<repeatBlock>

\<ifBlock> =
  if \<logical> \[ \<return> \] then {\<singleThen> | \<return> \<multiThen>}

\<singleThen> = \<stmnt> \[ \[\<return>\] \<elseBlock> \]

\<multiThen> = \<stmntList> { end if | \<elseBlock>}

\<elseBlock> = else {\<stmnt> | \<return> \<stmntList> end if}

\<repeatBlock> =
  repeat \[forever | \<duration> | \<count> | with \<identifier> = \<range>\] \<return>
    \<stmntList>
  end repeat

\<duration> = until \<logical> | while \<logical>
\<count> = \[ for \] \<unsigned> \[ times \]
\<range> = \<integer> \[ down \] to \<integer>

### Expressions

\<expr> =
   \<source> | - \<factor> | not \<factor> | \<expr> \<op> \<expr> |
   (\<expr>) | \<chunk> \<factor>

\<op> =
  + | - | \* | / | & | && | ^ | = | < | > | <> | ≠ |
  <= | >= | ≤ | ≥ | and | or | contains | div | mod |
  is | is not | is in | is not in | is within | is not within

\<source> =
  \<literal> | \<constant> | \<simpleContainer> |
  \[ \<adjective> \] \<function> |
  \[ \<adjective> \] \<property> of {\<object> | \<window>}

\<literal> = "quoted string"

\<constant> =
  down | empty | false | formFeed | lineFeed |
  pi | quote | space | tab | true | up  |
  zero | one | two | three | four | five |
  six | seven | eight | nine | ten

\<adjective> = long | short | abbrev | abbr | abbreviated

\<function> =
  the \<theFunc> |
  \[ the \] \<theFunc> of \<oneFuncArg> |
  \<identifier> ( \<funcArgs> )

\<theFunc> =
  abs | atan | chartonum | clickh | clickloc |  clickv |
  commandKey | cmdKey | cos | date | diskspace |  exp |
  exp1 | exp2 | foundChunk | foundField | foundLine |
  foundText|  heapspace | length | ln | ln1 | log2 | mouse |
  mouseclick |  mouseh | mouseloc | mousev | number |
  numtochar | optionKey |  param | paramcount | params |
  random | result | round | screenrect |  seconds | secs |
  selectedChunk | selectedField | selectedLine | selectedText |
  shiftKey | sin | sound | sqrt | stackspace | tan |  target |
  ticks | time | tool | trunc | value

Syntax for each individual property appears in the [Functions section](#1.2.5-functions).

\<property> =
  autoHilite | autoTab | blindTyping | botRight | bottom |
  bottomRight | brush | cantDelete | cantModify | centered |
  cursor | dragSpeed | editBkgnd | filled | freeSize | grid |
  height | highlight | highlite | hilight | hilite | icon |
  id | language | left | lineSize | loc | location |
  lockMessages | lockRecent | lockScreen | lockText |
  multiple | multiSpace | name | numberFormat | pattern |
  polySides | powerKeys | rect | rectangle | right |
  script | scroll | showLines | showName | showPict |
  size | style | textAlign | textArrows | textFont |
  textHeight | textSize | textStyle | top | topLeft |
  userLevel | userModify | version | visible | wideMargins | width

Syntax for each individual property appears at the end of the [Commands section](#1.2.5-commands), in the [notes about the **set** command](#1.2.5-set-notes).

### Objects

\<object> =
  {HyperCard | me | \[ the \] target | \<button> | \<field> |
  \<card> | \<bkgnd>}@ | \<stack>

**Note:** "card field 1" is a field and "card (field 1)" is a card.

\<button> =
  {button id \<unsignedFactor> | button {\<factor> | \<token>} |
  \<ordinal> button} \[ of \<card> \]

\<field> =
  {field id \<unsignedFactor> | field {\<factor> | \<token>} |
  \<ordinal> field} \[ of \<card> \]

\<part> = \<button> | \<field>

\<ordinal> =
  last | mid | middle | any |
  first | second | third | fourth | fifth |
  sixth | seventh | eigth | ninth | tenth

\<card> =
  recent card | back | forth |
  {card id \<unsigned> | card {\<expr> | \<token>} |
  card \<endLine> | \<ordinal> card | \<position> card} \[ of \<bkgnd> \]

\<position> = this | prev | next

\<bkgnd> =
  bkgnd id \<unsigned> | bkgnd {\<expr> | \<token>} |
  bkgnd \<endLine> | \<ordinal> bkgnd | \<position> bkgnd

\<stack> =
  {this stack | stack {\<expr> | \<line>} | stack \<endLine>}@ |
  {@{\<expr> | \<line>}}

### Containers

\<simpleContainer> = \<variable> | \<field> | \<messageBox> | \[ the \] selection

\<container> = \<chunk> \<simpleContainer> | \<simpleContainer>

\<messageBox> = \[ the \] msg \[ box | window \]

\<chunk> =
  \[{\<ordinal> char | char \<expr> \[ to \<expr> \]} of\]
  \[{\<ordinal> word | word \<expr> \[ to \<expr> \]} of\]
  \[{\<ordinal> item | item \<expr> \[ to \<expr> \]} of\]
  \[{\<ordinal> line | line \<expr> \[ to \<expr> \]} of\]

### Commands

#### Command Nonterminals

These nonterminals appear in the command syntax that follows.

\<dateItems> =
  \<unsigned>,\<unsigned>,\<unsigned>,\<unsigned>,
  \<unsigned>,\<unsigned>,\<unsigned>

\<date> =
  \<unsigned> | \<dateItems>
  \<humanDate> \[ \<humanTime> \] |
  \<humanTime> \[ \<humanDate> \]

\<dateFormat> = \[ \<adjective> \] {seconds | dateItems | date | time}

\<dayOfWeek> =
  Sunday | Sun | Monday | Mon | Tuesday | Tue | Wednesday |
  Wed | Thursday | Thu | Friday | Fri | Saturday | Sat

\<dest> =
  {{\<card> | \<bkgnd>} \[ of \<stack> \]}@ | \<stack>

\<duration> = until \<logical> | while \<logical>

\<humanDate> =
  \[ \<dayOfWeek> , \] \<month> \<unsigned> , \<unsigned> |
  \<unsignedFactor> {/ | -} \<unsignedFactor> {/ | -} \<unsignedFactor>

\<humanTime> =
  \<unsigned> : \<unsigned> \[ : \<unsigned> \] \[ am | pm \]

\<month> =
  January | Jan | February | Feb | March | Mar |
  April | Apr | May | June | Jun | July | Jul |
  August | Aug | September | Sep | October | Oct |
  November | Nov | December | Dec

\<point> = {\<integer> , \<integer>}@

\<preposition> = before | after | into

\<rect> = {\<integer> , \<integer> , integer> , \<integer>}@

\<springKeys> = \<springKeys> , \<springKey> | \<springKey>

\<springKey> = shiftKey | optionKey | commandKey

\<style> =
  {transparent | opaque | rectangle | roundrect |
  shadow | checkBox | radioButton | scrolling}@

\<textAlign> = {right | left | center}@

\<textStyleList> = \<textStyleList> \<textStyle> | \<textStyle>

\<textStyle> =
  {plain | bold | italic | underline | outline |
  shadow |condense | extend}@

\<visEffect> = \<visKind> \[ \[ very \] {slow | slowly | fast} \] \[ to \<visSrc> \]

\<visKind> =
  barn door {open | close} |
  cut | plain | dissolve | venetian blinds | checkerboard |
  iris {open | close} |
  scroll {left | right | up | down} |
  wipe {left | right | up | down} |
  zoom {open | out | close | in }

\<visSrc> = card | black | white | gray | inverse

\<window> = {card | pattern | tool} window | \<messageBox>

#### Commands

add
  \<arith> to \<container>
answer
  {\<expr> | \<token>} \[with {\<factor> | \<token>} \[or {\<factor> | \<token>} \[or {\<factor> | \<token>} \]\]\]
arrowkey
  left | right | up | down
ask
  \[ password \] {\<expr> | \<token>} \[ with {\<expr> | \<line>} \]
beep
  \[\<unsigned>\]
choose
  {tool \<unsigned>}@ |
  {browse | button | field | select | lasso | pencil |
  brush | eraser | line | spray \[ can \] | rect |   
  round rect | bucket | oval | curve | text |
  reg poly | poly} tool}@
click
  at \<point> \[ with \<springKeys> \]
close
  file {\<expr> | \<line>} | printing
controlkey
  \<unsigned>
convert
  {\<container> | \<date>} to \<dateFormat> \[ and \<dateFormat> \]
debug
  {\<expr> | \<line>}
delete
  {\<chunk> \<simpleContainer>}@
dial
  \<expr> \[ with modem | with \[ modem \] \<expr> \]
divide
  \<container> by \<float>
domenu
  \<expr> | \<line>
drag
  from \<point> to \<point> \[ with \<springKeys> \]
edit
  \[ the \] script of \<object>
enterInField
enterkey
find
  \[ whole | string | words | word | chars | normal \]
  {\<expr> | \<token>} \[ in \<field> \]
functionkey
  \<unsigned>
get
  \<expr> | \[ the \] \<property> \[ of \<object> \]
go
  \[ to \] {{\<ordinal> | \<position>} \<endLine> | \<dest>}
help
hide
  menuBar | picture of {\<object>}@ |
  { card | bkgnd } picture | \<window> | {\<part>}@
lock
  screen
multiply
  \<container> by \<arith>
open
  printing \[ with dialog \] |
  file {\<expr> | \<line>} |
  {\<expr> | \<token>} \[ with {\<expr> | \<line>} \] |
  \<expr> | \<line>
play
  stop | {\<expr> | \<token>} \[ \[ tempo \<unsigned> \] {\<expr> | \<line>} \]
pop
  card \[ \<preposition> \<container> \]
print
  {\<expr> | \<token>} with {\<expr> | \<line>} |
  \<unsigned> cards | all cards | \<card>
push
  \<dest>
put
  {\<expr> | \<token>} \[ \<preposition> \<container> \]
read
  from file {\<expr> | \<token>} {until {\<expr> | \<token>} | for \<unsigned>}
reset
  paint
returnInField
returnkey
select
  {\[ before | after \] {{text of | \<chunk> } { \<field> | \<message>}@}@} |
  {\<part>}@ | \<emptyExpr>
set
  \[ the \] \<property> \[ of {\<window> | \<object>} \] to \<propVal>

(See [notes on **set**](#1.2.5-set-notes), below.)

show
  menuBar | picture of {\<object>}@ |
  { card | bkgnd } picture |
  {\<window> | {\<part>}@} \[ at \<point> \] |
  \[ all | \<unsigned> \] cards
sort
  \[ ascending | descending \]
  \[ text | numeric | international | dateTime \]
    by \<expr>
subtract
  \<arith> from \<container>
tabkey
type
  \<expr> \[ with \<springKeys> \]
unlock
  screen \[ with {\[ visual \[ effect \]\] \<visEffect>}@ \]
visual
  \[ effect \] \<visEffect>
wait
  \<duration> | \<count> \[ ticks | tick | seconds | second | sec \]
write
  \<expr> to file {\<expr> | \<line>}

The following syntax refers only to the **set** command. The general syntax for **set** is:

  \[ the \] \<property> \[ of {\<window> | \<object>} \] to \<propVal>

\<propVal> =
  {\<expr> | \<line>} | \<integer> | \<unsigned> | \<logical> |
  \<point> | \<rect> | \<style> | \<textAlign> | \<textStyleList>

**Set** has a different syntax for different groups of properties. The following list shows which nonterminals apply to which properties:

{\<expr> | \<line>}
  name,textFont,icon,script,language,cursor,numberFormat
\<integer>
  top,bottom,left,right,width,height
\<unsigned>
  textHeight,textSize,lineSize,pattern,brush,polySides,
  multiSpace,userLevel,dragSpeed,scroll
\<logical>
  freeSize,showName,lockText,showLines,wideMargins,visible,
  powerKeys,grid,filled,centered,multiple,editBkgnd,hilite,
  lockScreen,lockRecent,autoHilite,blindTyping,lockMessages,
  textArrows,showPict,cantDelete,cantModify,autoTab,userModify
\<point>
  loc,topLeft,botRight
\<rect>
  rect
\<style>
  style
\<textAlign>
  textAlign
\<textStyleList>
  textStyle

### Functions

Note that` <funcArith>`,` <funcFloat>`,` <funcExpr>`, and`  <funcUnsigned>  ` all take expressions when they're called with parentheses, but they all take factors when they're called with "of".

abs
  \<funcArith>
annuity
  \<float> , \<float>
atan
  \<funcFloat>
average
  {\<arithList>}@
chartonum
  \<funcExpr>
clickh
clickloc
clickv
commandkey
compound
  \<float> , \<float>
cos
  \<funcFloat>
date
diskspace
exp
  \<funcFloat>
exp1
  \<funcFloat>
exp2
  \<funcFloat>
foundChunk
foundField
foundLine
foundText
heapspace
length
  \<funcExpr>
ln
  \<funcFloat>
ln1
  \<funcFloat>
log2
  \<funcFloat>
max
  {\<arithList>}@
min
  {\<arithList>}@
mouse
mouseclick
mouseh
mouseloc
mousev
number
  cards \[ in \<bkgnd> \] |  bkgnds |
  \[ card | bkgnd \] {buttons | fields} |
  {chars | words | items | lines} in \<funcExpr> |
  \<object>
numtochar
  \<funcUnsigned>
offset
  \<string> , \<string>
optionkey
param
  \<funcUnsigned>
paramcount
params
random
  \<funcUnsigned>
result
round
  \<funcFloat>
screenrect
seconds
selectedChunk
selectedField
selectedLine
selectedText
shiftkey
sin
  \<funcFloat>
sound
sqrt
  \<funcFloat>
stackspace
tan
  \<funcFloat>
target
ticks
time
tool
trunc
  \<funcFloat>
value
  \<funcExpr>

---

## Formal Syntax of HyperTalk Version 2.2

This section describes the One True Syntax for the HyperTalk scripting language on the Macintosh, HyperCard version 2.2. It shows precisely what's allowed in every construct. It uses the syntax symbols listed in the [Syntax Symbols section](#syntax-symbols).

HyperTalk 2.x syntax is much simpler than the syntax of earlier versions, making it closer to natural language. It allows automatic expansion (designated in the 1.2 syntax by the @ sign) throughout the language: HyperTalk 2.x accepts an expression in place of any nonterminal or any sublist (items enclosed in square brackets or curly braces). It allows unquoted tokens everywhere, and the use of the ancillary "the" is allowed in more cases.

These new freedoms have a minor cost. In previous versions of HyperTalk, "in" and "of" were lexically equivalent. In HyperTalk 2.x, there are two places where they're not:

- when you use find expr in field (indicated by the nonterminal` <inOnly>`)
- when you refer to properties - for example, the name of card 1 (indicated by the nonterminal`  <ofOnly>`)

This restriction does not hold in versions before 2.0 because they are fully interpreted, and thus have information not available to a compiler that lets them handle these cases properly.

### Scripts

\<script> = \<script> \<handler> | \<handler>

\<handler> = \<return> \<handler> |
  on \<messageKey> \<return>
    \<stmntList>
  end \<messageKey> \<return>

\<stmntList> = \<stmnt> | \<stmntList> \<stmnt>

\<stmnt> = {\<messageSend> | \<keywordStmnt> | \<empty>} \<return>

\<keywordStmnt> =
  do \<expr> |
  exit repeat | exit \<messageKey> | exit to HyperCard |
  global \<identList> |
  next repeat |
  pass \<messageKey> |
  return \<expr> |
  send \<expr> \[ to {\<object> | window \<expr>} | program \<expr>\] |
  \<ifBlock> | \<repeatBlock>

\<ifBlock> =
  if \<logical> \[ \<return> \] then {\<singleThen> | \<return> \<multiThen>}

\<singleThen> = \<stmnt> \[ \[\<return>\] \<elseBlock> \]

\<multiThen> = \<stmntList> { end if | \<elseBlock>}

\<elseBlock> = else {\<stmnt> | \<return> \<stmntList> end if}

\<repeatBlock> =
  repeat \[ forever | \<duration> | \<count> | with \<identifier> = \<range> \] \<return>
    \<stmntList>
  end repeat

\<duration> = until \<logical> | while \<logical>
\<count> = \[ for \] \<unsigned> \[ times \]
\<range> = \<integer> \[ down \] to \<integer>

### Expressions

\<expr> =
  \<source> | - \<expr> | not \<expr | \<expr> \<op> \<expr> |
  ( \<expr> ) | \<chunk> \<expr> | there is { a | an | no } \<expr>

\<op> =
  + | - | \* | / | & | && | ^ | = | < | > | <> | ≠ |
  <= | >= | ≤ | ≥ | and | or | contains | div | mod |
  is | is not | is in | is not in | is within | is not within |
  is a\[n\] | is not a\[n\]

\<source> =
  \<literal> | \<constant> | \<simpleContainer> |
  \[ \<adjective> \] \<function> |
  \[ \<adjective> \] \<property> of {\<object> | \<window> |
  \<menuItem> of \<menu> | \<chunk> \<field> }

\<literal> = "quoted string" | unquotedToken

\<constant> =
  down | empty | false | formFeed | lineFeed |
  pi | quote | space | tab | true | up  |
  zero | one | two | three | four | five |
  six | seven | eight | nine | ten

\<adjective> = long | short | abbrev | abbr | abbreviated

\<window> = \[the\] {card | pattern | tool | scroll } window | \<messageBox>

\<menuItem> = \<ordinal> menuItem | menuItem \<expr>
\<menu> = \<ordinal> menu | menu \<expr>

\<function> =
  the \<theFunc> | \[ the \] \<theFunc> of \<oneFuncArg> |
  \<identifier> ( \<funcArgs> )

\<theFunc> =
  abs | annuity | atan | average | charToNum | clickChunk | clickH |
  clickLine | clickLoc | clickText | clickV | cmdKey | commandKey |
  compound | cos | date | diskSpace | exp | exp1 | exp2 | foundChunk |
  foundField | foundLine | foundText | heapSpace | length | ln | ln1 |
  log2 | max | menus | min | mouse | mouseClick | mouseH | mouseLoc |
  mouseV | number | numToChar | offset | optionKey | param |
  paramCount | params | programs | random | result | round |
  screenRect | seconds | selectedButton | selectedChunk |
  selectedField | selectedLine | selectedLoc | selectedText |
  shiftKey | sin | sound | sqrt | stacks | stackSpace | sum |
  systemVersion | tan | target | ticks | time | tool | trunc |
  value | windows

Syntax for each individual function appears in the [Functions section](#2.2-functions).

\<property> =
  address | autoHilite | autoSelectautoTab | blindTyping |
  botRight | bottom | bottomRight | brush | cantAbort |
  cantDelete | cantModify | cantPeek | centered | checkMark |
  cmdChar | commandChar | cursor | debugger | dialingTime |
  dialingVolume | dontSearch | dontWrap | dragSpeed | editBkgnd |
  enabled | environment | family | filled | fixedLineHeight |
  freeSize | grid | height | highlight | highlite | hilight |
  hilite | icon | id | itemDelimiter | language | left |
  lineSize | loc | location | lockErrorDialogs | lockMessages |
  lockRecent | lockScreen | lockText | longWindowTitles |
  markChar | marked | menuMessage | menuMsg | messageWatcher |
  multiple | multipleLines | multiSpace | name | numberFormat |
  owner | partNumber | pattern | polySides | powerKeys |
  printMargins | printTextAlign | printTextFont |
  printTextHeight | printTextSize | printTextStyle | rect |
  rectangle | reportTemplates | right | script | scriptEditor |
  scriptingLanguage | scriptTextFont | scriptTextSize | scroll |
  sharedHilite | sharedText | showLines | showName | showPict |
  size | stacksInUse | style | suspended | textAlign |
  textArrows | textFont | textHeight | textSize | textStyle |
  titleWidth | top | topLeft | traceDelay | userLevel |
  userModify | variableWatcher | version | visible | wideMargins |
  width | zoomed

Syntax for each individual property appears at the end of the [Commands section](#2.2-commands), in the [notes about the **set** command](#2.2-set-notes).

### Ordinals and Positions

\<ordinal> =  \[ the \]
  { last | mid | middle | any |
  first | second | third | fourth | fifth |
  sixth | seventh | eigth | ninth | tenth }

\<position> = this | \[ the \] prev | \[ the \] next

### Chunks and Containers

\<simpleContainer> =
  \<variable> | \<part> | \<menu> |
  \<messageBox> | \[ the \] selection

\<container> = \<chunk> \<simpleContainer> | \<simpleContainer>

\<messageBox> = \[ the \] msg \[ box | window \]

\<chunk> =
  \[{\<ordinal> char | char \<expr> \[ to \<expr> \]} of\]
  \[{\<ordinal> word | word \<expr> \[ to \<expr> \]} of\]
  \[{\<ordinal> item | item \<expr> \[ to \<expr> \]} of\]
  \[{\<ordinal> line | line \<expr> \[ to \<expr> \]} of\]

### Objects

\<object> =
  HyperCard | me | \[ the \] target | \<button> | \<field> |
  \<card> | \<bkgnd> | \<stack>

Note: "card field 1" is a field and "card (field 1)" is a card.

\<button> =
  {button id \<unsignedFactor> | button \<factor> | \<ordinal> button} \[ of \<card> \]

\<field> =
  {field id \<unsignedFactor> | field \<factor> | \<ordinal> field} \[ of \<card> \]

\<part> =
  \<button> | \<field> | {part id \<unsignedFactor> |
  part \<factor> | \<ordinal> part} \[ of \<card> \]

\<card> =
  recent card | back | forth |
  card id \<unsigned> | card \<expr> | card \<endLine> | \<ordinal> card |
  \<position> card} \[ of \<bkgnd> \] |
  \<ordinal> marked card | \<position> marked card | marked card \<expr>

\<bkgnd> =
  bkgnd id \<unsigned> | bkgnd \<expr> | bkgnd \<endLine> |
  \<ordinal> bkgnd | \<position> bkgnd

\<stack> = this stack | stack \<expr> | stack \<endLine>

### Commands

#### Command Nonterminals

These nonterminals appear in the command syntax that follows.

\<dateItems> =
  \<unsigned>,\<unsigned>,\<unsigned>,\<unsigned>,
  \<unsigned>,\<unsigned>,\<unsigned>

\<date> =
  \<unsigned> | \<dateItems>
  \<humanDate> \[ \<humanTime> \] |
  \<humanTime> \[ \<humanDate> \]

\<dateFormat> = \[ \<adjective> \] {seconds | dateItems | date | time}

\<dayOfWeek> =
  Sunday | Sun | Monday | Mon | Tuesday | Tue | Wednesday |
  Wed | Thursday | Thu | Friday | Fri | Saturday | Sat

\<dest> =
  { \<card> | \<bkgnd> } \[ of \<stack> \] | \<stack> |
  { \<card> | \<bkgnd> }  of \[ \<stack> \] \<exprOrLine>

\<duration> = until \<logical> | while \<logical>

\<humanDate> =
  \[ \<dayOfWeek> , \] \<month> \<unsigned> , \<unsigned> |
  \<unsignedFactor> {/ | -} \<unsignedFactor> {/ | -} \<unsignedFactor>

\<humanTime> =
  \<unsigned> : \<unsigned> \[ : \<unsigned> \] \[ am | pm \]

\<month> =
  January | Jan | February | Feb | March | Mar |
  April | Apr | May | June | Jun | July | Jul |
  August | Aug | September | Sep | October | Oct |
  November | Nov | December | Dec

\<point> = {\<integer> , \<integer>}

\<preposition> = before | after | into

\<rect> = {\<integer> , \<integer> , integer> , \<integer>}

\<springKeys> = \<springKeys> , \<springKey> | \<springKey>

\<springKey> = shiftKey | optionKey | commandKey

\<style> =
  transparent | opaque | rectangle | roundrect |
  shadow | checkBox | radioButton | scrolling | oval | popup

\<textAlign> = right | left | center

\<textStyleList> = \<textStyleList> \<textStyle> | \<textStyle>

\<textStyle> =
  plain | bold | italic | underline | outline |
  shadow |condense | extend | group

\<visEffect> = \<visKind> \[ \[ very \] {slow | slowly | fast} \] \[ to \<visSrc> \]

\<visKind> =
  barn door {open | close} |
  cut | plain | dissolve | venetian blinds | checkerboard |
  iris {open | close} |
  scroll {left | right | up | down} |
  wipe {left | right | up | down} |
  zoom {open | out | close | in } |
  shrink to {top | bottom | center } |
  stretch from {top | bottom | center } |
  push {left | right | up | down}

\<visSrc> = card | black | white | gray | inverse

\<window> = {card | pattern | tool | scroll | fatBits} window | \<messageBox>

#### Commands

add
  \<arith> to \<container>
answer
  \<expr> \[with \<factor> \[or \<factor> \[or \<factor>\]\]\] |
  file \<expr> \[ of type \<factor> \[or \<factor> \[or \<factor>\]\]\] |
  program \<expr> of type \<factor>
arrowkey
  left | right | up | down
ask
  { password | file } \<expr> \[ with \<expr> | \<line> \]
beep
  \[\<unsigned>\]
choose
  tool \<unsigned> |
  { browse | button | field | select | lasso | pencil |
  brush | eraser | line | spray \[ can \] | rect |   
  round rect | bucket | oval | curve | text |
  reg poly | poly } tool
click
  at \<point> \[ with \<springKeys> \]
close
  file \<exprOrLine> | printing | application \<exprOrLine> | \<window>
commandKeyDown
  \<expr>
controlkey
  \<unsigned>
convert
  { \<container> | \<date>} \[from \<dateFormat> \[and \<dateFormat> \] \]
  to \<dateFormat> \[ and \<dateFormat> \]
copy
  template \<expr> to \<stack>
create
  stack \<expr> \[ with \<bkgnd> \] \[ in \[a\] new window \]
  | menu \<expr> \]
debug
  hintBits | pureQuickDraw { true | false }  | checkPoint |
  maxmem |Êsound { on | off }
delete
  \<chunk> \<simpleContainer> | \[\<menuItemExpr> { of | from }\] \<menuExpr>
  \<part>
dial
  \<expr> \[ with modem | with \[ modem \] \<expr> \]
disable
  \[ \<menuItem> of \] \<menu> | \<button>
divide
  \<container> by \<float>
domenu
  \<exprOrLine> | \<expr> \[ , \<expr> \] \[ without dialog \]
drag
  from \<point> to \<point> \[ with \<springKeys> \]
edit
  \[ the \] script of \<object>
enable
  \[ \<menuItem> of \] \<menu> | \<button>
enterInField
enterKey
export
  paint to file \<expr>
find
  \[ whole | string | words | word | chars | normal \]
  \[ international \] \<expr> \[ in \<field> \] \[ \<ofOnly> marked cards \]
functionkey
  \<unsigned>
get
  \<expr> |
  \[ the \] \<property>
  \[ of { \<window> | \<object> | \[ \<menuItem> of \] \<menu> |
  \<chunk> \<field> }\]
go
  \[ to \] {{\<ordinal> | \<position>} \<endLine> |
  \<dest>} \[ in \[ a \] new window \] \[ without dialog \]
help
hide
  menuBar | picture of \<object> |
  { card | bkgnd } picture | \<window> | \<part>
import
  paint from file \<expr>
keyDown
  \<expr>
lock
  screen | messages | error dialogs | recent
mark
  all cards | \<card> | cards where \<expr>
  | cards by finding \[ whole | string | words | word | chars | normal \]
  \[ international \] \<expr> \[ in \<field> \]
multiply
  \<container> by \<arith>
open
  \[report\] printing \[ with dialog \] |
  file \<exprOrLine> |
  \<expr> \[ with \<exprOrLine> \] |
  \<exprOrLine>
play
  stop | \<expr> \[ \[ tempo \<unsigned> \] \<exprOrLine> \]
pop
  card \[ \<preposition> \<container> \]
print
  \<expr> with \<exprOrLine> |
  \<unsigned> cards | all cards | marked cards | \<card> |
  \<field> | \<expr>
push
  \<dest>
put
  \<expr> \[ \<preposition> \[\<container> | \[ \<menuItem> of \]
  \<menu> \[with menuMessage\[s\] \<expr> \]\]
read
  from file \<expr> {until \<expr> | for \<unsigned>}
reply
  \<expr> \[ with keyword \<expr> \]
  error \<expr>
request
  \<expr> { of | from } \<expr>
  { ae | appleEvent } { class | ID | sender | returnID
  | data \[ { of | with } keyword \<expr> \] }
reset
  paint | menubar | printing
returnInField
returnkey
save
  { \[ this \] stack | stack \<expr> } as \[ stack \] \<expr>
select
  \[ before | after \] {text of | \<chunk> } { \<field> | \<message>} |
  \<part> | \<emptyExpr>
set
  \[ the \] \<property> \[ \<ofOnly> {\<window> | \<object> |
  \<menuItem> of \<menu> | \<chunk> \<field>} \] to \<propVal>

(See [Notes on **set**](#2.2-set-notes) below.)

show
  menuBar | picture of \<object> |
  { card | bkgnd } picture |
  {\<window> | \<part>} \[ at \<point> \] |
  \[ all | marked | \<unsigned> \] cards
sort
  \[ \[cards of \] { this stack | \<bkgnd> } | marked cards }
  \[ ascending | descending \]
  \[ text | numeric | international | dateTime \]
  by \<expr>
  \[ { lines | items } of \] \<container> by \<expr>
start
  using \<stack>
stop
  using \<stack>
subtract
  \<arith> from \<container>
tabKey
type
  \<expr> \[ with \<springKeys> \]
unlock
  screen \[ with \[ visual \[ effect \]\] \<visEffect> \]
  | error dialogs | recent | messages
unmark
  all cards | \<card> | cards where \<expr>
  | cards by finding \[ whole | string | words | word | chars | normal \]
  \[ international \] \<expr> \[ in \<field> \]
visual
  \[ effect \] \<visEffect>
wait
  \<duration> | \<count> \[ ticks | tick | seconds | second | sec \]
write
  \<expr> to file \<exprOrLine>

**Notes on set:** The following syntax refers only to the **set** command.

\<style> =
  transparent | opaque | rectangle | roundrect |
  shadow | checkBox | radioButton | scrolling | oval | popup

\<textAlign> = right | left | center

\<textStyleList> = \<textStyleList> \<textStyle> | \<textStyle>

\<textStyle> =
  plain | bold | italic | underline | outline |
  shadow | condense | extend | group

\<propVal> =
  \<exprOrLine> | \<integer> | \<unsigned> | \<logical> | \<point> |
  \<rect> | \<style> | \<textAlign> | \<textStyleList>

`*exprOrLine*`

`commandChar, cursor, debugger, environment, itemDelimiter, language, markChar, menuMessage, messageWatcher, name, numberFormat, owner, printTextFont, reportTemplates, script, scriptEditor, scriptingLanguage, scriptTextFont, stacksInUse, textFont, variableWatcher, version`

`*integer*`

`top, bottom, left, right, width, height`

`*unsigned*`

`brush, dialingTime, dialingVolume, dragSpeed, family, freeSize, icon, ID, lineSize, multiSpace, partNumber, pattern, polySides, printTextHeight, printTextSize, scriptTextSize, scroll, size, textHeight, textSize, titleWidth, traceDelay, userLevel`

`*logical*`

`autoHilite, autoSelect, autoTab, blindTyping, cantAbort, cantDelete, cantModify, cantPeek, centered, checkMark, dontSearch, dontWrap, editBkgnd, enabled, filled, fixedLineHeight, grid, hilite, lockErrorDialogs, lockMessages, lockRecent, lockScreen, lockText, longWindowTitles, marked, multiple, multipleLines, powerKeys, sharedHilite, sharedText, showLines, showName, showPict, suspended, textArrows, userModify, visible, wideMargins, zoomed`

`*point*`

`loc, topLeft, botRight, bottomRight, scroll (of window)`

`*rect*`

`rect, printMargins`

`*style*`

`style`

`*textAlign*`

`textAlign, printTextAlign`

`*textStyleList*`

`printTextStyle,textStyle`

### Functions

Note:` <funcArth>`,` <funcFloat>`,` <funcExpr>`, and` <funcUnsigned>` all take expressions where they're called with parentheses, but factors otherwise.

abs
  \<funcArith>
annuity
  \<float> , \<float>
atan
  \<funcFloat>
average
  \<arithList>
charToNum
  \<funcExpr>
clickChunk
clickH
clickLine
clickLoc
clickText
clickV
cmdKey
commandKey
compound
  \<float> , \<float>
cos
  \<funcFloat>
date
diskSpace
exp
  \<funcFloat>
exp1
  \<funcFloat>
exp2
  \<funcFloat>
foundChunk
foundField
foundLine
foundText
heapSpace
length
  \<funcExpr>
ln
  \<funcFloat>
ln1
  \<funcFloat>
log2
  \<funcFloat>
max
  \<arithList>
menus
min
  \<arithList>
mouse
mouseClick
mouseH
mouseLoc
mouseV
number
  cards \[ in \<bkgnd> \] |  bkgnds |
  \[ card | bkgnd \] {buttons | fields | parts} |
  {chars | words | items | lines} in \<funcExpr> |
  \<object> |
  menus | menuItems {in | of } \<menu> | marked cards | windows
numToChar
  \<funcUnsigned>
offset
  \<string> , \<string>
optionKey
param
  \<funcUnsigned>
paramCount
params
random
  \<funcUnsigned>
result
round
  \<funcFloat>
screenRect
seconds
selectedButton
  \[card | bkgnd\] family \<funcUnsigned>
selectedChunk
selectedField
selectedLine
selectedLoc
selectedText
shiftKey
sin
  \<funcFloat>
sound
sqrt
  \<funcFloat>
stacks
stackSpace
sum
  \<arithList>
systemVersion
tan
  \<funcFloat>
target
ticks
time
tool
trunc
  \<funcFloat>
value
  \<funcExpr>
windows