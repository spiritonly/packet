# This module is separated for isolation during testing. It is not meant to be
# exposed as part of the public API.

# Regular expression to match a pipeline argument, expressed as a JavaScript
# scalar, taken in part from [json2.js](http://www.JSON.org/json2.js). 
{argument, constant} = require "./argument"
next = /^(-?)([xbl])(\d+)([fa]?)(.*)$/

number = (pattern, index) ->
  if match = /^(&)?0x([0-9a-f]+)(.*)$/i.exec pattern
    [ false, !! match[1], parseInt(match[2], 16), index + (match[1] or "").length + 2 + match[2].length, match[3] ]
  else if match = /^(\d+)(.*)$/.exec pattern
    [ false, false, parseInt(match[1], 10), index + match[1].length, match[2] ]
  else if match = /^\*(.*)$/
    [ true, false, 0, 1, match[1] ]
  else
    throw new Error "invalid pattern at index #{index}"

condition = (struct, text, index) ->
  [ any, mask, value, index, range ] = number text, index
  if mask
    struct.mask = value
  else if not any
    if  range[0] is "-"
      index++
      [ any, mask, maximum, nextIndex, range ] = number range.substring(1), index
      if mask
        throw new Error "masks not permitted in ranges at index #{index}"
      if any
        throw new Error "asterisk not permitted in ranges at index #{index}"
      index = nextIndex
      if match = /(\s*)\S/.test range
        throw new Error "invalid pattern at index #{index + match[1].length}"
      struct.minimum = value
      struct.maximum = maximum
    else
      struct.minimum = struct.maximum = value
  index

FAILURE =
  minimum: Number.MIN_VALUE
  maximum: Number.MAX_VALUE
  mask: 0

always = ->
  {
    maximum: Number.MAX_VALUE
    minimum: Number.MIN_VALUE
    mask: 0
  }

never = ->
  {
    maximum: Number.MIN_VALUE
    minimum: Number.MAX_VALUE
  }

alternates = (array, rest, primary, secondary, allowSecondary, index) ->
  while rest
    alternate             = {}
    alternate[primary]    = always()
    alternate[secondary]  = if allowSecondary then always() else never()

    match = /^([^/:]+)(?:(\s*\/\s*)([^:]+))?(:\s*)(.*)$/.exec rest
    if match
      [ first, delimiter, second, imparative, rest ] = match.slice(1)
      startIndex = index
      condition alternate[primary], first, index
      if allowSecondary
        if second
          condition alternate[secondary], second, index
        else
          alternate[secondary] = alternate[primary]
      else if second
        slashIndex = startIndex + first.length + delimiter.indexOf("/")
        throw new Error "field alternates not allowed at index #{slashIndex}"
      index += first.length + imparative.length
      index += delimiter.length + second.length if delimiter?

    if match = /^(\s*)([^|]+)(\|\s*)(.*)$/.exec rest
      [ padding, pattern, delimiter, rest ] = match.slice(1)
    else
      [ padding, pattern, delimiter, rest ] = [ "", rest, "", null ]
    index += padding.length
    alternate.pattern = parse({ pattern, index, next, bits: 8 })
    index += pattern.length + delimiter.length

    array.push alternate

##### parse(pattern)
# Parse a pattern and create a list of fields.

# The `pattern` is the pattern to parse.
module.exports.parse = (pattern) -> parse({ pattern, index: 0, next, bits: 8 })

parse = (o) ->
  fields          = []
  lengthEncoded   = false

  # We chip away at the pattern, removing the parts we've matched, while keeping
  # track of the index separately for error messages.
  rest            = o.pattern
  index           = o.index
  loop
    # Match a packet pattern.
    match = o.next.exec(rest)

    # The 6th field is a trick to reuse this method for bit packing patterns
    # which are limited in what they can do. For bit packing the 5th pattern
    # will match the rest only if it begins with a comma or named field arrow,
    # otherwise it falls to the 6th which matches.
    if !match
      throw  new Error "invalid pattern at index #{index}"
    if match[6]
      throw  new Error "invalid pattern at index #{index + rest.length - match[6].length}"

    # The remainder of the pattern, if any.
    rest = match[5]

    # Convert the match into an object.
    f =
      signed:     !!match[1] || match[4] == "f"
      endianness: if match[2] == 'n' then 'b' else match[2]
      bits:       parseInt(match[3], 10)
      type:       match[4] || 'n'

    # Move the character position up to the bit count.
    index++ if match[1]
    index++

    # Check for a valid character
    if f.bits == 0
      throw new Error("bit size must be non-zero at index #{index}")
    if f.bits % o.bits
      throw new Error("bit size must be divisible by #{o.bits} at index #{index}")
    if f.type == "f" and !(f.bits == 32 || f.bits == 64)
      throw Error("floats can only be 32 or 64 bits at index #{index}")

    # Move the character position up to the rest of the pattern.
    index += match[3].length
    index++ if match[4]

    # Set the implicit fields. Unpacking logic is inconsistant between bits and
    # bytes, but not applicable for bits anyway.
    f.type      = "a" if f.bits > 64 and f.type == "n"
    f.bytes     = f.bits / o.bits
    f.unpacked  = f.signed or f.bytes > 8 or "ha".indexOf(f.type) != -1


    # Check for bit backing. The intense rest pattern allows us to skip over a
    # nested padding specifier in the bit packing pattern, nested curly brace
    # matching for a depth of one.
    pack = /^{((?:-b|b|x).+)}(\s*,.*|\s*)$/.exec(rest)
    if pack
      f.packing   = parse
                      pattern: pack[1]
                      bits: 1
                      index: index + 1
                      next: /^(-?)([xb])(\d+)()(\s*(?:,|=>|{\d).*|)(.*)$/
      rest        = pack[2]
      index      += pack[1].length + 2
    # Check for alternation.
    else if alternation = /^\(([^)]+)\)(.*)$/.exec(rest)
      f.arrayed     = true
      read          = alternation[1]
      rest          = alternation[2]
      write         = null
      if alternation = /^(\s*\/\s*)\(([^)]+)\)(.*)$/.exec(rest)
        slash         = alternation[1]
        write         = alternation[2]
        rest          = alternation[3]
      index += 1
      alternates f.alternation = [], read, "read", "write", not write, index
      index += read.length + 1
      if write
        index += slash.length + 1
        alternates f.alternation, write, "write", "read", false, index
        index += write.length
      f.alternation.push {
        read: FAILURE, write: FAILURE, failed: true
      }
    else
      # Check if this is a length encoding.
      length = /^\/(.*)$/.exec(rest)
      if length
        f.lengthEncoding = true
        rest = length[1]
        f.arrayed = false
        f.repeat = 1
        lengthEncoded = true
        fields.push(f)
        # Nothing else can apply to a length encoding.
        continue

      f.repeat    = 1
      f.arrayed   = lengthEncoded
      if not lengthEncoded
        # Check for structure modifiers.
        arrayed = /^\[(\d+)\](.*)$/.exec(rest)
        if arrayed
          f.arrayed = true
          f.repeat = parseInt(arrayed[1], 10)
          index++
          if f.repeat == 0
            throw new Error("array length must be non-zero at " + index)
          index += arrayed[1].length + 1
          rest = arrayed[2]

      # Check for a padding value.
      padding = /^{(0x|0)?(\d+)}(.*)$/.exec(rest)
      if padding
        base      = padding[1]
        pad       = padding[2]
        rest      = padding[3]

        if base
          if base == "0x"
            f.padding = parseInt(pad, 16)
          else
            f.padding = parseInt(pad, 8)
        else
          f.padding = parseInt(pad, 10)

      # Check for zero termination.
      tz = /^z(?:<(.*?)>)?(.*)$/.exec(rest)
      if tz
        index += rest.length - tz[2].length
        f.terminator = tz[1] or "\0"
        f.arrayed = true
        rest = tz[2]
        if f.repeat is 1
          f.repeat = Number.MAX_VALUE

      # Parse piplines.
      while pipe = /^\|(\w[\w\d]*)\((\)?)(.*)/.exec(rest)
        index          += rest.length - pipe[3].length
        transform       = { name: pipe[1], parameters: [] }
        rest            = pipe[3]
        hasArgument     = not pipe[2]

        while hasArgument
          arg         = argument.exec(rest)
          index      += rest.length - arg[3].length
          value       = eval(arg[1])
          hasArgument = arg[2].indexOf(")") is -1
          rest        = arg[3]

          transform.parameters.push(value)

        (f.pipeline or= []).push(transform)

      # Named pattern.
      name = /\s*=>\s*(\w[\w\d]+)\s*(.*)/.exec(rest)
      if name
        index += rest.length - name[2].length
        f.name = name[1]
        rest = name[2]

    # Record the new field pattern object.
    fields.push(f)

    # A comma indicates that we're to continue.
    more = /^(\s*,\s*)(.*)$/.exec(rest)
    break if not more

    # Reset for the next iteration.
    index += more[1].length
    rest = more[2]
    lengthEncoded = false

  if /\S/.test(rest)
    throw  new Error "invalid pattern at index #{index}"

  fields
