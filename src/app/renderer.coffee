_ = require 'underscore'
Highlighter = require 'highlighter'
LineMap = require 'line-map'
Point = require 'point'
EventEmitter = require 'event-emitter'
Range = require 'range'
Fold = require 'fold'
ScreenLineFragment = require 'screen-line-fragment'
Token = require 'token'
foldPlaceholderLength = 3

module.exports =
class Renderer
  @idCounter: 1
  lineMap: null
  highlighter: null
  activeFolds: null
  foldsById: null
  lastHighlighterChangeEvent: null
  foldPlaceholderLength: 3

  constructor: (@buffer, options={}) ->
    @id = @constructor.idCounter++
    @highlighter = new Highlighter(@buffer, options.tabText ? '  ')
    @maxLineLength = options.maxLineLength ? Infinity
    @activeFolds = {}
    @foldsById = {}
    @buildLineMap()
    @highlighter.on 'change', (e) => @lastHighlighterChangeEvent = e
    @buffer.on "change.renderer#{@id}", (e) => @handleBufferChange(e)

  buildLineMap: ->
    @lineMap = new LineMap
    @lineMap.insertAtBufferRow 0, @buildLinesForBufferRows(0, @buffer.getLastRow())

  setMaxLineLength: (@maxLineLength) ->
    oldRange = @rangeForAllLines()
    @buildLineMap()
    newRange = @rangeForAllLines()
    @trigger 'change', { oldRange, newRange }

  lineForRow: (row) ->
    @lineMap.lineForScreenRow(row)

  linesForRows: (startRow, endRow) ->
    @lineMap.linesForScreenRows(startRow, endRow)

  getLines: ->
    @lineMap.linesForScreenRows(0, @lineMap.lastScreenRow())

  bufferRowsForScreenRows: (startRow, endRow) ->
    @lineMap.bufferRowsForScreenRows(startRow, endRow)

  createFold: (bufferRange) ->
    bufferRange = Range.fromObject(bufferRange)
    return if bufferRange.isEmpty()

    fold = new Fold(this, bufferRange)
    @registerFold(bufferRange.start.row, fold)

    # If this fold starts on a screen line that contains other folds, we'll
    # need to the re-render the screen lines corresponding to these preceding
    # folds as well.  So we alter the start row of the buffer range we
    # are going to change to the buffer row of the first fold in a potential
    # series of folds that ends on the current fold's starting buffer row.
    bufferRange = bufferRange.copy()
    bufferRange.start.row = @bufferRowForScreenRow(@screenRowForBufferRow(bufferRange.start.row))

    oldScreenRange = @screenLineRangeForBufferRange(bufferRange)
    lines = @buildLineForBufferRow(bufferRange.start.row)
    @lineMap.replaceScreenRows(oldScreenRange.start.row, oldScreenRange.end.row, lines)
    newScreenRange = @screenLineRangeForBufferRange(bufferRange)

    @trigger 'change', oldRange: oldScreenRange, newRange: newScreenRange
    @trigger 'fold', bufferRange
    fold

  destroyFold: (fold) ->
    bufferRange = fold.getRange().copy()
    @unregisterFold(bufferRange.start.row, fold)

    bufferRange.start.row = @bufferRowForScreenRow(@screenRowForBufferRow(bufferRange.start.row))
    startScreenRow = @screenRowForBufferRow(bufferRange.start.row)

    oldScreenRange = @screenLineRangeForBufferRange(bufferRange)
    lines = @buildLinesForBufferRows(bufferRange.start.row, bufferRange.end.row)
    @lineMap.replaceScreenRows(
      oldScreenRange.start.row,
      oldScreenRange.end.row
      lines)
    newScreenRange = @screenLineRangeForBufferRange(bufferRange)

    @trigger 'change', oldRange: oldScreenRange, newRange: newScreenRange
    @trigger 'unfold', fold.getRange()

  screenRowForBufferRow: (bufferRow) ->
    @lineMap.screenPositionForBufferPosition([bufferRow, 0]).row

  bufferRowForScreenRow: (screenRow) ->
    @lineMap.bufferPositionForScreenPosition([screenRow, 0]).row

  screenRangeForBufferRange: (bufferRange) ->
    @lineMap.screenRangeForBufferRange(bufferRange)

  bufferRangeForScreenRange: (screenRange) ->
    @lineMap.bufferRangeForScreenRange(screenRange)

  lineCount: ->
    @lineMap.screenLineCount()

  screenPositionForBufferPosition: (position, options) ->
    @lineMap.screenPositionForBufferPosition(position, options)

  bufferPositionForScreenPosition: (position, options) ->
    @lineMap.bufferPositionForScreenPosition(position, options)

  clipScreenPosition: (position, options={}) ->
    @lineMap.clipScreenPosition(position, options)

  handleBufferChange: (e) ->
    for row, folds of @activeFolds
      for fold in new Array(folds...)
        changeInsideFold = true if fold.handleBufferChange(e)

    unless changeInsideFold
      @handleHighlighterChange(@lastHighlighterChangeEvent)

  handleHighlighterChange: (e) ->
    oldBufferRange = e.oldRange.copy()
    newBufferRange = e.newRange.copy()

    oldBufferRange.start.row = @bufferRowForScreenRow(@screenRowForBufferRow(oldBufferRange.start.row))
    newBufferRange.start.row = @bufferRowForScreenRow(@screenRowForBufferRow(newBufferRange.start.row))

    oldScreenRange = @screenLineRangeForBufferRange(oldBufferRange)
    newScreenLines = @buildLinesForBufferRows(newBufferRange.start.row, newBufferRange.end.row)
    @lineMap.replaceScreenRows oldScreenRange.start.row, oldScreenRange.end.row, newScreenLines
    newScreenRange = @screenLineRangeForBufferRange(newBufferRange)

    @trigger 'change', { oldRange: oldScreenRange, newRange: newScreenRange, bufferChanged: true }

  buildLineForBufferRow: (bufferRow) ->
    @buildLinesForBufferRows(bufferRow, bufferRow)

  buildLinesForBufferRows: (startBufferRow, endBufferRow) ->
    lineFragments = []
    startBufferColumn = null
    currentScreenLineLength = 0

    loop
      break if startBufferRow > endBufferRow and not startBufferColumn?
      startBufferColumn ?= 0
      line = @highlighter.lineForRow(startBufferRow)
      line = line.splitAt(startBufferColumn)[1]
      wrapScreenColumn = @findWrapColumn(line.text, @maxLineLength - currentScreenLineLength)

      continueMainLoop = false
      for fold in @foldsForBufferRow(startBufferRow)
        if fold.start.column >= startBufferColumn
          foldStartSceenColumn = fold.start.column - startBufferColumn
          if (foldStartSceenColumn) > wrapScreenColumn - foldPlaceholderLength
            wrapScreenColumn = Math.min(wrapScreenColumn, foldStartSceenColumn)
            break
          prefix = line.splitAt(foldStartSceenColumn)[0]
          placeholder = @buildFoldPlaceholder(fold)
          lineFragments.push(prefix, placeholder)
          startBufferRow = fold.end.row
          startBufferColumn = fold.end.column
          currentScreenLineLength = currentScreenLineLength + (prefix?.text.length ? 0) + foldPlaceholderLength
          continueMainLoop = true
          break
      continue if continueMainLoop

      if wrapScreenColumn?
        line = line.splitAt(wrapScreenColumn)[0]
        line.screenDelta = new Point(1, 0)
        startBufferColumn += wrapScreenColumn
      else
        startBufferRow++
        startBufferColumn = null

      lineFragments.push(line)
      currentScreenLineLength = 0

    lineFragments

  findWrapColumn: (line, maxLineLength) ->
    return unless line.length > maxLineLength

    if /\s/.test(line[maxLineLength])
      # search forward for the start of a word past the boundary
      for column in [maxLineLength..line.length]
        return column if /\S/.test(line[column])
      return line.length
    else
      # search backward for the start of the word on the boundary
      for column in [maxLineLength..0]
        return column + 1 if /\s/.test(line[column])
      return maxLineLength

  registerFold: (bufferRow, fold) ->
    @activeFolds[bufferRow] ?= []
    @activeFolds[bufferRow].push(fold)
    @foldsById[fold.id] = fold

  unregisterFold: (bufferRow, fold) ->
    folds = @activeFolds[bufferRow]
    folds.splice(folds.indexOf(fold), 1)
    delete @foldsById[fold.id]

  foldsForBufferRow: (bufferRow) ->
    folds = @activeFolds[bufferRow] or []
    folds.sort (a, b) -> a.compare(b)

  buildFoldPlaceholder: (fold) ->
    token = new Token(value: '...', type: 'fold-placeholder', fold: fold, isAtomic: true)
    new ScreenLineFragment([token], token.value, [0, token.value.length], fold.getRange().toDelta())

  screenLineRangeForBufferRange: (bufferRange) ->
    @expandScreenRangeToLineEnds(
      @lineMap.screenRangeForBufferRange(
        @expandBufferRangeToLineEnds(bufferRange)))

  expandScreenRangeToLineEnds: (screenRange) ->
    screenRange = Range.fromObject(screenRange)
    { start, end } = screenRange
    new Range([start.row, 0], [end.row, @lineMap.lineForScreenRow(end.row).text.length])

  expandBufferRangeToLineEnds: (bufferRange) ->
    bufferRange = Range.fromObject(bufferRange)
    { start, end } = bufferRange
    new Range([start.row, 0], [end.row, Infinity])

  rangeForAllLines: ->
    new Range([0, 0], @clipScreenPosition([Infinity, Infinity]))

  destroy: ->
    @highlighter.destroy()
    @buffer.off ".renderer#{@id}"

  logLines: (start, end) ->
    @lineMap.logLines(start, end)

_.extend Renderer.prototype, EventEmitter
