#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# this module folds constants; used by semantic checking phase
# and evaluation phase

import
  strutils, options, ast, astalgo, trees, treetab, nimsets, times,
  nversion, platform, math, msgs, os, condsyms, idents, renderer, types,
  commands, magicsys, modulegraphs, strtabs, lineinfos

proc newIntNodeT*(intVal: BiggestInt, n: PNode; g: ModuleGraph): PNode =
  case skipTypes(n.typ, abstractVarRange).kind
  of tyInt:
    result = newIntNode(nkIntLit, intVal)
    # See bug #6989. 'pred' et al only produce an int literal type if the
    # original type was 'int', not a distinct int etc.
    if n.typ.kind == tyInt:
      result.typ = getIntLitType(g, result)
    else:
      result.typ = n.typ
    # hrm, this is not correct: 1 + high(int) shouldn't produce tyInt64 ...
    #setIntLitType(result)
  of tyChar:
    result = newIntNode(nkCharLit, intVal)
    result.typ = n.typ
  else:
    result = newIntNode(nkIntLit, intVal)
    result.typ = n.typ
  result.info = n.info

proc newFloatNodeT*(floatVal: BiggestFloat, n: PNode; g: ModuleGraph): PNode =
  result = newFloatNode(nkFloatLit, floatVal)
  if skipTypes(n.typ, abstractVarRange).kind == tyFloat:
    result.typ = getFloatLitType(g, result)
  else:
    result.typ = n.typ
  result.info = n.info

proc newStrNodeT*(strVal: string, n: PNode; g: ModuleGraph): PNode =
  result = newStrNode(nkStrLit, strVal)
  result.typ = n.typ
  result.info = n.info

proc getConstExpr*(m: PSym, n: PNode; g: ModuleGraph): PNode
  # evaluates the constant expression or returns nil if it is no constant
  # expression
proc evalOp*(m: TMagic, n, a, b, c: PNode; g: ModuleGraph): PNode

proc checkInRange(conf: ConfigRef; n: PNode, res: BiggestInt): bool =
  if res in firstOrd(conf, n.typ)..lastOrd(conf, n.typ):
    result = true

proc foldAdd(a, b: BiggestInt, n: PNode; g: ModuleGraph): PNode =
  let res = a +% b
  if ((res xor a) >= 0'i64 or (res xor b) >= 0'i64) and
      checkInRange(g.config, n, res):
    result = newIntNodeT(res, n, g)

proc foldSub*(a, b: BiggestInt, n: PNode; g: ModuleGraph): PNode =
  let res = a -% b
  if ((res xor a) >= 0'i64 or (res xor not b) >= 0'i64) and
      checkInRange(g.config, n, res):
    result = newIntNodeT(res, n, g)

proc foldAbs*(a: BiggestInt, n: PNode; g: ModuleGraph): PNode =
  if a != firstOrd(g.config, n.typ):
    result = newIntNodeT(a, n, g)

proc foldMod*(a, b: BiggestInt, n: PNode; g: ModuleGraph): PNode =
  if b != 0'i64:
    result = newIntNodeT(a mod b, n, g)

proc foldModU*(a, b: BiggestInt, n: PNode; g: ModuleGraph): PNode =
  if b != 0'i64:
    result = newIntNodeT(a %% b, n, g)

proc foldDiv*(a, b: BiggestInt, n: PNode; g: ModuleGraph): PNode =
  if b != 0'i64 and (a != firstOrd(g.config, n.typ) or b != -1'i64):
    result = newIntNodeT(a div b, n, g)

proc foldDivU*(a, b: BiggestInt, n: PNode; g: ModuleGraph): PNode =
  if b != 0'i64:
    result = newIntNodeT(a /% b, n, g)

proc foldMul*(a, b: BiggestInt, n: PNode; g: ModuleGraph): PNode =
  let res = a *% b
  let floatProd = toBiggestFloat(a) * toBiggestFloat(b)
  let resAsFloat = toBiggestFloat(res)

  # Fast path for normal case: small multiplicands, and no info
  # is lost in either method.
  if resAsFloat == floatProd and checkInRange(g.config, n, res):
    return newIntNodeT(res, n, g)

  # Somebody somewhere lost info. Close enough, or way off? Note
  # that a != 0 and b != 0 (else resAsFloat == floatProd == 0).
  # The difference either is or isn't significant compared to the
  # true value (of which floatProd is a good approximation).

  # abs(diff)/abs(prod) <= 1/32 iff
  #   32 * abs(diff) <= abs(prod) -- 5 good bits is "close enough"
  if 32.0 * abs(resAsFloat - floatProd) <= abs(floatProd) and
      checkInRange(g.config, n, res):
    return newIntNodeT(res, n, g)

proc ordinalValToString*(a: PNode; g: ModuleGraph): string =
  # because $ has the param ordinal[T], `a` is not necessarily an enum, but an
  # ordinal
  var x = getInt(a)

  var t = skipTypes(a.typ, abstractRange)
  case t.kind
  of tyChar:
    result = $chr(int(x) and 0xff)
  of tyEnum:
    var n = t.n
    for i in countup(0, sonsLen(n) - 1):
      if n.sons[i].kind != nkSym: internalError(g.config, a.info, "ordinalValToString")
      var field = n.sons[i].sym
      if field.position == x:
        if field.ast == nil:
          return field.name.s
        else:
          return field.ast.strVal
    internalError(g.config, a.info, "no symbol for ordinal value: " & $x)
  else:
    result = $x

proc isFloatRange(t: PType): bool {.inline.} =
  result = t.kind == tyRange and t.sons[0].kind in {tyFloat..tyFloat128}

proc isIntRange(t: PType): bool {.inline.} =
  result = t.kind == tyRange and t.sons[0].kind in {
      tyInt..tyInt64, tyUInt8..tyUInt32}

proc pickIntRange(a, b: PType): PType =
  if isIntRange(a): result = a
  elif isIntRange(b): result = b
  else: result = a

proc isIntRangeOrLit(t: PType): bool =
  result = isIntRange(t) or isIntLit(t)

proc makeRange(typ: PType, first, last: BiggestInt; g: ModuleGraph): PType =
  let minA = min(first, last)
  let maxA = max(first, last)
  let lowerNode = newIntNode(nkIntLit, minA)
  if typ.kind == tyInt and minA == maxA:
    result = getIntLitType(g, lowerNode)
  elif typ.kind in {tyUint, tyUInt64}:
    # these are not ordinal types, so you get no subrange type for these:
    result = typ
  else:
    var n = newNode(nkRange)
    addSon(n, lowerNode)
    addSon(n, newIntNode(nkIntLit, maxA))
    result = newType(tyRange, typ.owner)
    result.n = n
    addSonSkipIntLit(result, skipTypes(typ, {tyRange}))

proc makeRangeF(typ: PType, first, last: BiggestFloat; g: ModuleGraph): PType =
  var n = newNode(nkRange)
  addSon(n, newFloatNode(nkFloatLit, min(first.float, last.float)))
  addSon(n, newFloatNode(nkFloatLit, max(first.float, last.float)))
  result = newType(tyRange, typ.owner)
  result.n = n
  addSonSkipIntLit(result, skipTypes(typ, {tyRange}))

proc evalIs(n, a: PNode): PNode =
  # XXX: This should use the standard isOpImpl
  #internalAssert a.kind == nkSym and a.sym.kind == skType
  #internalAssert n.sonsLen == 3 and
  #  n[2].kind in {nkStrLit..nkTripleStrLit, nkType}

  let t1 = a.sym.typ

  if n[2].kind in {nkStrLit..nkTripleStrLit}:
    case n[2].strVal.normalize
    of "closure":
      let t = skipTypes(t1, abstractRange)
      result = newIntNode(nkIntLit, ord(t.kind == tyProc and
                                        t.callConv == ccClosure and
                                        tfIterator notin t.flags))
    of "iterator":
      let t = skipTypes(t1, abstractRange)
      result = newIntNode(nkIntLit, ord(t.kind == tyProc and
                                        t.callConv == ccClosure and
                                        tfIterator in t.flags))
    else: discard
  else:
    # XXX semexprs.isOpImpl is slightly different and requires a context. yay.
    let t2 = n[2].typ
    var match = sameType(t1, t2)
    result = newIntNode(nkIntLit, ord(match))
  result.typ = n.typ

proc evalOp(m: TMagic, n, a, b, c: PNode; g: ModuleGraph): PNode =
  # b and c may be nil
  result = nil
  case m
  of mOrd: result = newIntNodeT(getOrdValue(a), n, g)
  of mChr: result = newIntNodeT(getInt(a), n, g)
  of mUnaryMinusI, mUnaryMinusI64: result = newIntNodeT(- getInt(a), n, g)
  of mUnaryMinusF64: result = newFloatNodeT(- getFloat(a), n, g)
  of mNot: result = newIntNodeT(1 - getInt(a), n, g)
  of mCard: result = newIntNodeT(nimsets.cardSet(g.config, a), n, g)
  of mBitnotI:
    case skipTypes(n.typ, abstractRange).kind
    of tyUInt..tyUInt64:
      result = newIntNodeT((not getInt(a)) and lastOrd(g.config, a.typ, fixedUnsigned=true), n, g)
    else:
      result = newIntNodeT(not getInt(a), n, g)
  of mLengthArray: result = newIntNodeT(lengthOrd(g.config, a.typ), n, g)
  of mLengthSeq, mLengthOpenArray, mXLenSeq, mLengthStr, mXLenStr:
    if a.kind == nkNilLit:
      result = newIntNodeT(0, n, g)
    elif a.kind in {nkStrLit..nkTripleStrLit}:
      result = newIntNodeT(len a.strVal, n, g)
    else:
      result = newIntNodeT(sonsLen(a), n, g)
  of mUnaryPlusI, mUnaryPlusF64: result = a # throw `+` away
  of mToFloat, mToBiggestFloat:
    result = newFloatNodeT(toFloat(int(getInt(a))), n, g)
  # XXX: Hides overflow/underflow
  of mToInt, mToBiggestInt: result = newIntNodeT(system.toInt(getFloat(a)), n, g)
  of mAbsF64: result = newFloatNodeT(abs(getFloat(a)), n, g)
  of mAbsI: result = foldAbs(getInt(a), n, g)
  of mZe8ToI, mZe8ToI64, mZe16ToI, mZe16ToI64, mZe32ToI64, mZeIToI64:
    # byte(-128) = 1...1..1000_0000'64 --> 0...0..1000_0000'64
    result = newIntNodeT(getInt(a) and (`shl`(1, getSize(g.config, a.typ) * 8) - 1), n, g)
  of mToU8: result = newIntNodeT(getInt(a) and 0x000000FF, n, g)
  of mToU16: result = newIntNodeT(getInt(a) and 0x0000FFFF, n, g)
  of mToU32: result = newIntNodeT(getInt(a) and 0x00000000FFFFFFFF'i64, n, g)
  of mUnaryLt: result = foldSub(getOrdValue(a), 1, n, g)
  of mSucc: result = foldAdd(getOrdValue(a), getInt(b), n, g)
  of mPred: result = foldSub(getOrdValue(a), getInt(b), n, g)
  of mAddI: result = foldAdd(getInt(a), getInt(b), n, g)
  of mSubI: result = foldSub(getInt(a), getInt(b), n, g)
  of mMulI: result = foldMul(getInt(a), getInt(b), n, g)
  of mMinI:
    if getInt(a) > getInt(b): result = newIntNodeT(getInt(b), n, g)
    else: result = newIntNodeT(getInt(a), n, g)
  of mMaxI:
    if getInt(a) > getInt(b): result = newIntNodeT(getInt(a), n, g)
    else: result = newIntNodeT(getInt(b), n, g)
  of mShlI:
    case skipTypes(n.typ, abstractRange).kind
    of tyInt8: result = newIntNodeT(int8(getInt(a)) shl int8(getInt(b)), n, g)
    of tyInt16: result = newIntNodeT(int16(getInt(a)) shl int16(getInt(b)), n, g)
    of tyInt32: result = newIntNodeT(int32(getInt(a)) shl int32(getInt(b)), n, g)
    of tyInt64, tyInt:
      result = newIntNodeT(`shl`(getInt(a), getInt(b)), n, g)
    of tyUInt..tyUInt64:
      result = newIntNodeT(`shl`(getInt(a), getInt(b)) and lastOrd(g.config, a.typ, fixedUnsigned=true), n, g)
    else: internalError(g.config, n.info, "constant folding for shl")
  of mShrI:
    case skipTypes(n.typ, abstractRange).kind
    of tyInt8: result = newIntNodeT(int8(getInt(a)) shr int8(getInt(b)), n, g)
    of tyInt16: result = newIntNodeT(int16(getInt(a)) shr int16(getInt(b)), n, g)
    of tyInt32: result = newIntNodeT(int32(getInt(a)) shr int32(getInt(b)), n, g)
    of tyInt64, tyInt, tyUInt..tyUInt64:
      result = newIntNodeT(`shr`(getInt(a), getInt(b)), n, g)
    else: internalError(g.config, n.info, "constant folding for shr")
  of mDivI: result = foldDiv(getInt(a), getInt(b), n, g)
  of mModI: result = foldMod(getInt(a), getInt(b), n, g)
  of mAddF64: result = newFloatNodeT(getFloat(a) + getFloat(b), n, g)
  of mSubF64: result = newFloatNodeT(getFloat(a) - getFloat(b), n, g)
  of mMulF64: result = newFloatNodeT(getFloat(a) * getFloat(b), n, g)
  of mDivF64:
    if getFloat(b) == 0.0:
      if getFloat(a) == 0.0: result = newFloatNodeT(NaN, n, g)
      elif getFloat(b).classify == fcNegZero: result = newFloatNodeT(-Inf, n, g)
      else: result = newFloatNodeT(Inf, n, g)
    else:
      result = newFloatNodeT(getFloat(a) / getFloat(b), n, g)
  of mMaxF64:
    if getFloat(a) > getFloat(b): result = newFloatNodeT(getFloat(a), n, g)
    else: result = newFloatNodeT(getFloat(b), n, g)
  of mMinF64:
    if getFloat(a) > getFloat(b): result = newFloatNodeT(getFloat(b), n, g)
    else: result = newFloatNodeT(getFloat(a), n, g)
  of mIsNil: result = newIntNodeT(ord(a.kind == nkNilLit), n, g)
  of mLtI, mLtB, mLtEnum, mLtCh:
    result = newIntNodeT(ord(getOrdValue(a) < getOrdValue(b)), n, g)
  of mLeI, mLeB, mLeEnum, mLeCh:
    result = newIntNodeT(ord(getOrdValue(a) <= getOrdValue(b)), n, g)
  of mEqI, mEqB, mEqEnum, mEqCh:
    result = newIntNodeT(ord(getOrdValue(a) == getOrdValue(b)), n, g)
  of mLtF64: result = newIntNodeT(ord(getFloat(a) < getFloat(b)), n, g)
  of mLeF64: result = newIntNodeT(ord(getFloat(a) <= getFloat(b)), n, g)
  of mEqF64: result = newIntNodeT(ord(getFloat(a) == getFloat(b)), n, g)
  of mLtStr: result = newIntNodeT(ord(getStr(a) < getStr(b)), n, g)
  of mLeStr: result = newIntNodeT(ord(getStr(a) <= getStr(b)), n, g)
  of mEqStr: result = newIntNodeT(ord(getStr(a) == getStr(b)), n, g)
  of mLtU, mLtU64:
    result = newIntNodeT(ord(`<%`(getOrdValue(a), getOrdValue(b))), n, g)
  of mLeU, mLeU64:
    result = newIntNodeT(ord(`<=%`(getOrdValue(a), getOrdValue(b))), n, g)
  of mBitandI, mAnd: result = newIntNodeT(a.getInt and b.getInt, n, g)
  of mBitorI, mOr: result = newIntNodeT(getInt(a) or getInt(b), n, g)
  of mBitxorI, mXor: result = newIntNodeT(a.getInt xor b.getInt, n, g)
  of mAddU: result = newIntNodeT(`+%`(getInt(a), getInt(b)), n, g)
  of mSubU: result = newIntNodeT(`-%`(getInt(a), getInt(b)), n, g)
  of mMulU: result = newIntNodeT(`*%`(getInt(a), getInt(b)), n, g)
  of mModU: result = foldModU(getInt(a), getInt(b), n, g)
  of mDivU: result = foldDivU(getInt(a), getInt(b), n, g)
  of mLeSet: result = newIntNodeT(ord(containsSets(g.config, a, b)), n, g)
  of mEqSet: result = newIntNodeT(ord(equalSets(g.config, a, b)), n, g)
  of mLtSet:
    result = newIntNodeT(ord(containsSets(g.config, a, b) and not equalSets(g.config, a, b)), n, g)
  of mMulSet:
    result = nimsets.intersectSets(g.config, a, b)
    result.info = n.info
  of mPlusSet:
    result = nimsets.unionSets(g.config, a, b)
    result.info = n.info
  of mMinusSet:
    result = nimsets.diffSets(g.config, a, b)
    result.info = n.info
  of mSymDiffSet:
    result = nimsets.symdiffSets(g.config, a, b)
    result.info = n.info
  of mConStrStr: result = newStrNodeT(getStrOrChar(a) & getStrOrChar(b), n, g)
  of mInSet: result = newIntNodeT(ord(inSet(a, b)), n, g)
  of mRepr:
    # BUGFIX: we cannot eval mRepr here for reasons that I forgot.
    discard
  of mIntToStr, mInt64ToStr: result = newStrNodeT($(getOrdValue(a)), n, g)
  of mBoolToStr:
    if getOrdValue(a) == 0: result = newStrNodeT("false", n, g)
    else: result = newStrNodeT("true", n, g)
  of mCopyStr: result = newStrNodeT(substr(getStr(a), int(getOrdValue(b))), n, g)
  of mCopyStrLast:
    result = newStrNodeT(substr(getStr(a), int(getOrdValue(b)),
                                           int(getOrdValue(c))), n, g)
  of mFloatToStr: result = newStrNodeT($getFloat(a), n, g)
  of mCStrToStr, mCharToStr:
    if a.kind == nkBracket:
      var s = ""
      for b in a.sons:
        s.add b.getStrOrChar
      result = newStrNodeT(s, n, g)
    else:
      result = newStrNodeT(getStrOrChar(a), n, g)
  of mStrToStr: result = a
  of mEnumToStr: result = newStrNodeT(ordinalValToString(a, g), n, g)
  of mArrToSeq:
    result = copyTree(a)
    result.typ = n.typ
  of mCompileOption:
    result = newIntNodeT(ord(commands.testCompileOption(g.config, a.getStr, n.info)), n, g)
  of mCompileOptionArg:
    result = newIntNodeT(ord(
      testCompileOptionArg(g.config, getStr(a), getStr(b), n.info)), n, g)
  of mEqProc:
    result = newIntNodeT(ord(
        exprStructuralEquivalent(a, b, strictSymEquality=true)), n, g)
  else: discard

proc getConstIfExpr(c: PSym, n: PNode; g: ModuleGraph): PNode =
  result = nil
  for i in countup(0, sonsLen(n) - 1):
    var it = n.sons[i]
    if it.len == 2:
      var e = getConstExpr(c, it.sons[0], g)
      if e == nil: return nil
      if getOrdValue(e) != 0:
        if result == nil:
          result = getConstExpr(c, it.sons[1], g)
          if result == nil: return
    elif it.len == 1:
      if result == nil: result = getConstExpr(c, it.sons[0], g)
    else: internalError(g.config, it.info, "getConstIfExpr()")

proc leValueConv*(a, b: PNode): bool =
  result = false
  case a.kind
  of nkCharLit..nkUInt64Lit:
    case b.kind
    of nkCharLit..nkUInt64Lit: result = a.intVal <= b.intVal
    of nkFloatLit..nkFloat128Lit: result = a.intVal <= round(b.floatVal).int
    else: result = false #internalError(a.info, "leValueConv")
  of nkFloatLit..nkFloat128Lit:
    case b.kind
    of nkFloatLit..nkFloat128Lit: result = a.floatVal <= b.floatVal
    of nkCharLit..nkUInt64Lit: result = a.floatVal <= toFloat(int(b.intVal))
    else: result = false # internalError(a.info, "leValueConv")
  else: result = false # internalError(a.info, "leValueConv")

proc magicCall(m: PSym, n: PNode; g: ModuleGraph): PNode =
  if sonsLen(n) <= 1: return

  var s = n.sons[0].sym
  var a = getConstExpr(m, n.sons[1], g)
  var b, c: PNode
  if a == nil: return
  if sonsLen(n) > 2:
    b = getConstExpr(m, n.sons[2], g)
    if b == nil: return
    if sonsLen(n) > 3:
      c = getConstExpr(m, n.sons[3], g)
      if c == nil: return
  result = evalOp(s.magic, n, a, b, c, g)

proc getAppType(n: PNode; g: ModuleGraph): PNode =
  if g.config.globalOptions.contains(optGenDynLib):
    result = newStrNodeT("lib", n, g)
  elif g.config.globalOptions.contains(optGenStaticLib):
    result = newStrNodeT("staticlib", n, g)
  elif g.config.globalOptions.contains(optGenGuiApp):
    result = newStrNodeT("gui", n, g)
  else:
    result = newStrNodeT("console", n, g)

proc rangeCheck(n: PNode, value: BiggestInt; g: ModuleGraph) =
  var err = false
  if n.typ.skipTypes({tyRange}).kind in {tyUInt..tyUInt64}:
    err = value <% firstOrd(g.config, n.typ) or value >% lastOrd(g.config, n.typ, fixedUnsigned=true)
  else:
    err = value < firstOrd(g.config, n.typ) or value > lastOrd(g.config, n.typ)
  if err:
    localError(g.config, n.info, "cannot convert " & $value &
                                     " to " & typeToString(n.typ))

proc foldConv*(n, a: PNode; g: ModuleGraph; check = false): PNode =
  # XXX range checks?
  case skipTypes(n.typ, abstractRange).kind
  of tyInt..tyInt64, tyUInt..tyUInt64:
    case skipTypes(a.typ, abstractRange).kind
    of tyFloat..tyFloat64:
      result = newIntNodeT(int(getFloat(a)), n, g)
    of tyChar: result = newIntNodeT(getOrdValue(a), n, g)
    else:
      result = a
      result.typ = n.typ
    if check and result.kind in {nkCharLit..nkUInt64Lit}:
      rangeCheck(n, result.intVal, g)
  of tyFloat..tyFloat64:
    case skipTypes(a.typ, abstractRange).kind
    of tyInt..tyInt64, tyEnum, tyBool, tyChar:
      result = newFloatNodeT(toBiggestFloat(getOrdValue(a)), n, g)
    else:
      result = a
      result.typ = n.typ
  of tyOpenArray, tyVarargs, tyProc:
    discard
  else:
    result = a
    result.typ = n.typ

proc getArrayConstr(m: PSym, n: PNode; g: ModuleGraph): PNode =
  if n.kind == nkBracket:
    result = n
  else:
    result = getConstExpr(m, n, g)
    if result == nil: result = n

proc foldArrayAccess(m: PSym, n: PNode; g: ModuleGraph): PNode =
  var x = getConstExpr(m, n.sons[0], g)
  if x == nil or x.typ.skipTypes({tyGenericInst, tyAlias, tySink}).kind == tyTypeDesc:
    return

  var y = getConstExpr(m, n.sons[1], g)
  if y == nil: return

  var idx = getOrdValue(y)
  case x.kind
  of nkPar, nkTupleConstr:
    if idx >= 0 and idx < sonsLen(x):
      result = x.sons[int(idx)]
      if result.kind == nkExprColonExpr: result = result.sons[1]
    else:
      localError(g.config, n.info, "index out of bounds: " & $n)
  of nkBracket:
    idx = idx - firstOrd(g.config, x.typ)
    if idx >= 0 and idx < x.len: result = x.sons[int(idx)]
    else: localError(g.config, n.info, "index out of bounds: " & $n)
  of nkStrLit..nkTripleStrLit:
    result = newNodeIT(nkCharLit, x.info, n.typ)
    if idx >= 0 and idx < len(x.strVal):
      result.intVal = ord(x.strVal[int(idx)])
    elif idx == len(x.strVal) and optLaxStrings in g.config.options:
      discard
    else:
      localError(g.config, n.info, "index out of bounds: " & $n)
  else: discard

proc foldFieldAccess(m: PSym, n: PNode; g: ModuleGraph): PNode =
  # a real field access; proc calls have already been transformed
  var x = getConstExpr(m, n.sons[0], g)
  if x == nil or x.kind notin {nkObjConstr, nkPar, nkTupleConstr}: return

  var field = n.sons[1].sym
  for i in countup(ord(x.kind == nkObjConstr), sonsLen(x) - 1):
    var it = x.sons[i]
    if it.kind != nkExprColonExpr:
      # lookup per index:
      result = x.sons[field.position]
      if result.kind == nkExprColonExpr: result = result.sons[1]
      return
    if it.sons[0].sym.name.id == field.name.id:
      result = x.sons[i].sons[1]
      return
  localError(g.config, n.info, "field not found: " & field.name.s)

proc foldConStrStr(m: PSym, n: PNode; g: ModuleGraph): PNode =
  result = newNodeIT(nkStrLit, n.info, n.typ)
  result.strVal = ""
  for i in countup(1, sonsLen(n) - 1):
    let a = getConstExpr(m, n.sons[i], g)
    if a == nil: return nil
    result.strVal.add(getStrOrChar(a))

proc newSymNodeTypeDesc*(s: PSym; info: TLineInfo): PNode =
  result = newSymNode(s, info)
  if s.typ.kind != tyTypeDesc:
    result.typ = newType(tyTypeDesc, s.owner)
    result.typ.addSonSkipIntLit(s.typ)
  else:
    result.typ = s.typ

proc getConstExpr(m: PSym, n: PNode; g: ModuleGraph): PNode =
  result = nil

  proc getSrcTimestamp(): DateTime =
    try:
      result = utc(fromUnix(parseInt(getEnv("SOURCE_DATE_EPOCH",
                                            "not a number"))))
    except ValueError:
      # Environment variable malformed.
      # https://reproducible-builds.org/specs/source-date-epoch/: "If the
      # value is malformed, the build process SHOULD exit with a non-zero
      # error code", which this doesn't do. This uses local time, because
      # that maintains compatibility with existing usage.
      result = local(getTime())

  case n.kind
  of nkSym:
    var s = n.sym
    case s.kind
    of skEnumField:
      result = newIntNodeT(s.position, n, g)
    of skConst:
      case s.magic
      of mIsMainModule: result = newIntNodeT(ord(sfMainModule in m.flags), n, g)
      of mCompileDate: result = newStrNodeT(format(getSrcTimestamp(),
                                                   "yyyy-MM-dd"), n, g)
      of mCompileTime: result = newStrNodeT(format(getSrcTimestamp(),
                                                   "HH:mm:ss"), n, g)
      of mCpuEndian: result = newIntNodeT(ord(CPU[g.config.target.targetCPU].endian), n, g)
      of mHostOS: result = newStrNodeT(toLowerAscii(platform.OS[g.config.target.targetOS].name), n, g)
      of mHostCPU: result = newStrNodeT(platform.CPU[g.config.target.targetCPU].name.toLowerAscii, n, g)
      of mBuildOS: result = newStrNodeT(toLowerAscii(platform.OS[g.config.target.hostOS].name), n, g)
      of mBuildCPU: result = newStrNodeT(platform.CPU[g.config.target.hostCPU].name.toLowerAscii, n, g)
      of mAppType: result = getAppType(n, g)
      of mNaN: result = newFloatNodeT(NaN, n, g)
      of mInf: result = newFloatNodeT(Inf, n, g)
      of mNegInf: result = newFloatNodeT(NegInf, n, g)
      of mIntDefine:
        if isDefined(g.config, s.name.s):
          try:
            result = newIntNodeT(g.config.symbols[s.name.s].parseInt, n, g)
          except ValueError:
            localError(g.config, n.info, "expression is not an integer literal")
      of mStrDefine:
        if isDefined(g.config, s.name.s):
          result = newStrNodeT(g.config.symbols[s.name.s], n, g)
      else:
        result = copyTree(s.ast)
    of skProc, skFunc, skMethod:
      result = n
    of skType:
      # XXX gensym'ed symbols can come here and cannot be resolved. This is
      # dirty, but correct.
      if s.typ != nil:
        result = newSymNodeTypeDesc(s, n.info)
    of skGenericParam:
      if s.typ.kind == tyStatic:
        if s.typ.n != nil and tfUnresolved notin s.typ.flags:
          result = s.typ.n
          result.typ = s.typ.base
      elif s.typ.isIntLit:
        result = s.typ.n
      else:
        result = newSymNodeTypeDesc(s, n.info)
    else: discard
  of nkCharLit..nkNilLit:
    result = copyNode(n)
  of nkIfExpr:
    result = getConstIfExpr(m, n, g)
  of nkCallKinds:
    if n.sons[0].kind != nkSym: return
    var s = n.sons[0].sym
    if s.kind != skProc and s.kind != skFunc: return
    try:
      case s.magic
      of mNone:
        # If it has no sideEffect, it should be evaluated. But not here.
        return
      of mSizeOf:
        var a = n.sons[1]
        if computeSize(g.config, a.typ) < 0:
          localError(g.config, a.info, "cannot evaluate 'sizeof' because its type is not defined completely")
          result = nil
        elif skipTypes(a.typ, typedescInst+{tyRange}).kind in
             IntegralTypes+NilableTypes+{tySet}:
          #{tyArray,tyObject,tyTuple}:
          result = newIntNodeT(getSize(g.config, a.typ), n, g)
        else:
          result = nil
          # XXX: size computation for complex types is still wrong
      of mLow:
        result = newIntNodeT(firstOrd(g.config, n.sons[1].typ), n, g)
      of mHigh:
        if skipTypes(n.sons[1].typ, abstractVar).kind notin
            {tySequence, tyString, tyCString, tyOpenArray, tyVarargs}:
          result = newIntNodeT(lastOrd(g.config, skipTypes(n[1].typ, abstractVar)), n, g)
        else:
          var a = getArrayConstr(m, n.sons[1], g)
          if a.kind == nkBracket:
            # we can optimize it away:
            result = newIntNodeT(sonsLen(a)-1, n, g)
      of mLengthOpenArray:
        var a = getArrayConstr(m, n.sons[1], g)
        if a.kind == nkBracket:
          # we can optimize it away! This fixes the bug ``len(134)``.
          result = newIntNodeT(sonsLen(a), n, g)
        else:
          result = magicCall(m, n, g)
      of mLengthArray:
        # It doesn't matter if the argument is const or not for mLengthArray.
        # This fixes bug #544.
        result = newIntNodeT(lengthOrd(g.config, n.sons[1].typ), n, g)
      of mAstToStr:
        result = newStrNodeT(renderTree(n[1], {renderNoComments}), n, g)
      of mConStrStr:
        result = foldConStrStr(m, n, g)
      of mIs:
        let a = getConstExpr(m, n[1], g)
        if a != nil and a.kind == nkSym and a.sym.kind == skType:
          result = evalIs(n, a)
      else:
        result = magicCall(m, n, g)
    except OverflowError:
      localError(g.config, n.info, "over- or underflow")
    except DivByZeroError:
      localError(g.config, n.info, "division by zero")
  of nkAddr:
    var a = getConstExpr(m, n.sons[0], g)
    if a != nil:
      result = n
      n.sons[0] = a
  of nkBracket:
    result = copyTree(n)
    for i in countup(0, sonsLen(n) - 1):
      var a = getConstExpr(m, n.sons[i], g)
      if a == nil: return nil
      result.sons[i] = a
    incl(result.flags, nfAllConst)
  of nkRange:
    var a = getConstExpr(m, n.sons[0], g)
    if a == nil: return
    var b = getConstExpr(m, n.sons[1], g)
    if b == nil: return
    result = copyNode(n)
    addSon(result, a)
    addSon(result, b)
  of nkCurly:
    result = copyTree(n)
    for i in countup(0, sonsLen(n) - 1):
      var a = getConstExpr(m, n.sons[i], g)
      if a == nil: return nil
      result.sons[i] = a
    incl(result.flags, nfAllConst)
  #of nkObjConstr:
  #  result = copyTree(n)
  #  for i in countup(1, sonsLen(n) - 1):
  #    var a = getConstExpr(m, n.sons[i].sons[1])
  #    if a == nil: return nil
  #    result.sons[i].sons[1] = a
  #  incl(result.flags, nfAllConst)
  of nkPar, nkTupleConstr:
    # tuple constructor
    result = copyTree(n)
    if (sonsLen(n) > 0) and (n.sons[0].kind == nkExprColonExpr):
      for i in countup(0, sonsLen(n) - 1):
        var a = getConstExpr(m, n.sons[i].sons[1], g)
        if a == nil: return nil
        result.sons[i].sons[1] = a
    else:
      for i in countup(0, sonsLen(n) - 1):
        var a = getConstExpr(m, n.sons[i], g)
        if a == nil: return nil
        result.sons[i] = a
    incl(result.flags, nfAllConst)
  of nkChckRangeF, nkChckRange64, nkChckRange:
    var a = getConstExpr(m, n.sons[0], g)
    if a == nil: return
    if leValueConv(n.sons[1], a) and leValueConv(a, n.sons[2]):
      result = a              # a <= x and x <= b
      result.typ = n.typ
    else:
      localError(g.config, n.info,
        "conversion from $1 to $2 is invalid" %
          [typeToString(n.sons[0].typ), typeToString(n.typ)])
  of nkStringToCString, nkCStringToString:
    var a = getConstExpr(m, n.sons[0], g)
    if a == nil: return
    result = a
    result.typ = n.typ
  of nkHiddenStdConv, nkHiddenSubConv, nkConv:
    var a = getConstExpr(m, n.sons[1], g)
    if a == nil: return
    result = foldConv(n, a, g, check=n.kind == nkHiddenStdConv)
  of nkCast:
    var a = getConstExpr(m, n.sons[1], g)
    if a == nil: return
    if n.typ != nil and n.typ.kind in NilableTypes:
      # we allow compile-time 'cast' for pointer types:
      result = a
      result.typ = n.typ
  of nkBracketExpr: result = foldArrayAccess(m, n, g)
  of nkDotExpr: result = foldFieldAccess(m, n, g)
  of nkStmtListExpr:
    if n.len == 2 and n[0].kind == nkComesFrom:
      result = getConstExpr(m, n[1], g)
  else:
    discard
