###
# Omelette Simple Auto Completion for Node
###
{EventEmitter} = require "events"
path           = require "path"
fs             = require "fs"
os             = require "os"

depthOf = (object) ->
  level = 1
  for own key of object
    if typeof object[key] is 'object'
      depth = depthOf(object[key]) + 1
      level = Math.max(depth, level)
  level

# Removes all occurrences of `needle` from `haystack`
removeSubstring = (haystack, needle) ->
  haystack.replace (new RegExp (needle.replace /[\-\[\]\/\{\}\(\)\*\+\?\.\\\^\$\|]/g, "\\$&"), 'g'), ''

class Omelette extends EventEmitter

  {log} = console

  constructor: ->
    super()
    @asyncs   = 0
    @compgen  = process.argv.indexOf "--compgen"
    @install  = process.argv.indexOf("--completion") > -1
    @installFish  = process.argv.indexOf("--completion-fish") > -1
    isZsh     = process.argv.indexOf("--compzsh") > -1
    isFish    = process.argv.indexOf("--compfish") > -1
    @isDebug  = process.argv.indexOf("--debug") > -1

    @fragment = parseInt(process.argv[@compgen+1])-(if isZsh then 1 else 0)
    @line     = process.argv.slice(@compgen+3).join(' ')
    @word     = @line?.trim().split(/\s+/).pop()

    {@HOME, @SHELL} = process.env
    @mainProgram = ()->

  setProgram: (programs)->
    programs = programs.split '|'
    [@program] = programs
    @programs = programs.map (program)-> program.replace ///
      [
       ^     # Do not allow except:
        A-Z  # .. uppercase
        a-z  # .. lowercase
        0-9  # .. numbers
        \.   # .. dots
        \_   # .. underscores
        \-   # .. dashes
      ]
    ///g, ''

  setFragments: (@fragments...)->

  generate: ->
    data = {before: @word, @fragment, @line, @reply}
    @emit "complete", @fragments[@fragment-1], data
    @emit @fragments[@fragment-1], data
    @emit "$#{@fragment}", data
    if @asyncs is 0
      process.exit()

  reply: (words=[])->
    writer = (options)->
      console.log options.join? os.EOL
      process.exit()
    if words instanceof Promise
      words.then(writer)
    else
      writer(words)

  next: (handler) ->
    @mainProgram = handler if typeof handler is 'function'

  tree: (objectTree={})->
    depth = depthOf objectTree
    for level in [1..depth]
      @on "$#{level}", ({ fragment, reply, line })->
        if !(/\s+/.test( line.slice(-1) )) then lastIndex = -1
        accessor = new Function '_', """
          return _['#{line.split(/\s+/).slice(1, lastIndex).filter(Boolean).join("']['")}']
        """
        replies = if fragment is 1 then Object.keys(objectTree) else accessor(objectTree)
        reply do (replies = replies)->
          return replies() if replies instanceof Function
          return replies if replies instanceof Array
          return Object.keys(replies) if replies instanceof Object
    this

  generateCompletionCode: ->
    completions = @programs.map (program)=>
      completion = "_#{program}_completion"
      """
      ### #{program} completion - begin. generated by omelette.js ###
      if type compdef &>/dev/null; then
        #{completion}() {
          compadd -- `#{@program} --compzsh --compgen "${CURRENT}" "${words[CURRENT-1]}" "${BUFFER}"`
        }
        compdef #{completion} #{program}
      elif type complete &>/dev/null; then
        #{completion}() {
          local cur prev nb_colon
          _get_comp_words_by_ref -n : cur prev
          nb_colon=$(grep -o ":" <<< "$COMP_LINE" | wc -l)

          COMPREPLY=( $(compgen -W '$(#{@program} --compbash --compgen "$((COMP_CWORD - (nb_colon * 2)))" "$prev" "${COMP_LINE}")' -- "$cur") )

          __ltrim_colon_completions "$cur"
        }
        complete -F #{completion} #{program}
      elif type compctl &>/dev/null; then
        #{completion} () {
          local cword line point si
          read -Ac words
          read -cn cword
          read -l line
          si="$IFS"
          if ! IFS=$'\n' reply=($(#{program} --compzsh --compgen "${cword}" "${words[cword-1]}" "${line}")); then
            local ret=$?
            IFS="$si"
            return $ret
          fi
          IFS="$si"
        }
        compctl -K #{completion} #{program}
      fi
      ### #{program} completion - end ###
      """

    # Adding aliases for testing purposes
    completions.push @generateTestAliases() if @isDebug
    completions.join os.EOL

  generateCompletionCodeFish: ->
    completions = @programs.map (program)=>
      completion = "_#{program}_completion"
      """
      ### #{program} completion - begin. generated by omelette.js ###
      function #{completion}
        #{@program} --compfish --compgen (count (commandline -poc)) (commandline -pt) (commandline -pb)
      end
      complete -f -c #{program} -a '(#{completion})'
      ### #{program} completion - end ###
      """

    # Adding aliases for testing purposes
    completions.push @generateTestAliases() if @isDebug
    completions.join os.EOL

  generateTestAliases: ->
    fullPath = path.join process.cwd(), @program
    debugAliases   = @programs.map((program)-> "  alias #{program}=#{fullPath}").join os.EOL
    debugUnaliases = @programs.map((program)-> "  unalias #{program}").join os.EOL

    """
    ### test method ###
    omelette-debug-#{@program}() {
    #{debugAliases}
    }
    omelette-nodebug-#{@program}() {
    #{debugUnaliases}
    }
    ### tests ###
    """

  checkInstall: ->
    if @install
      log @generateCompletionCode()
      process.exit()
    if @installFish
      log @generateCompletionCodeFish()
      process.exit()

  getActiveShell: ->
    throw new Error 'Shell could not be detected' unless @SHELL

    if @SHELL.match /bash/      then 'bash'
    else if @SHELL.match /zsh/  then 'zsh'
    else if @SHELL.match /fish/ then 'fish'
    else throw new Error "Unsupported shell: #{@SHELL}"

  getDefaultShellInitFile: ->

    fileAt = (root)->
      (file)-> path.join root, file

    fileAtHome = fileAt @HOME

    switch @shell = @getActiveShell()
      when 'bash'  then fileAtHome '.bash_profile'
      when 'zsh'   then fileAtHome '.zshrc'
      when 'fish'  then fileAtHome '.config/fish/config.fish'

  getCompletionBlock: ()->
    command = switch @shell
      when 'bash'
        completionPath = path.join @HOME, ".#{@program}", 'completion.sh'
        "source #{completionPath}"
      when 'zsh'   then ". <(#{@program} --completion)"
      when 'fish'  then "#{@program} --completion-fish | source"
    
    if command
      """

      # begin #{@program} completion
      #{command}
      # end #{@program} completion

      """

  setupShellInitFile: (initFile=@getDefaultShellInitFile())->
    # @shell might be undefined if an `initFile` was passed
    @shell ?= @getActiveShell()

    # Special treatment for bash to handle extra folder
    if @shell is 'bash'
      programFolder = path.join @HOME, ".#{@program}"
      completionPath = path.join programFolder, 'completion.sh'

      fs.mkdirSync programFolder unless fs.existsSync programFolder
      fs.writeFileSync completionPath, @generateCompletionCode()

    # For every shell, write completion block to the init file
    fs.appendFileSync initFile, @getCompletionBlock()

    process.exit()

  cleanupShellInitFile: (initFile=@getDefaultShellInitFile())->
    # @shell might be undefined if an `initFile` was passed
    @shell ?= @getActiveShell()

    # For every shell, rewrite the init file
    if fs.existsSync initFile
      cleanedInitFile = removeSubstring (fs.readFileSync initFile, 'utf8'), @getCompletionBlock()
      fs.writeFileSync initFile, cleanedInitFile

    # Special treatment for bash to handle extra folder
    if @shell is 'bash'
      programFolder = path.join @HOME, ".#{@program}"
      completionPath = path.join programFolder, 'completion.sh'

      fs.unlinkSync completionPath if fs.existsSync completionPath
      fs.rmdirSync programFolder if (fs.existsSync programFolder) and (fs.readdirSync programFolder).length is 0

    process.exit()

  init: ->
    if @compgen > -1 then @generate() else @mainProgram()

  onAsync: (event, handler)->
    super.on(event, handler)
    @asyncs += 1

module.exports = (template, args...)->
  if template instanceof Array and args.length > 0
    [program, callbacks] = [template[0].trim(), args]
    fragments = callbacks.map (callback, index) -> "arg#{index}"
  else
    [program, fragments...] = template.split /\s+/
    callbacks = []

  fragments = fragments.map (fragment)-> fragment.replace /^\<+|\>+$/g, ''
  _omelette = new Omelette
  _omelette.setProgram program
  _omelette.setFragments fragments...
  _omelette.checkInstall()
  for callback, index in callbacks
    fragment = "arg#{index}"
    do (callback = callback)->
      _omelette.on fragment, (args...)->
        @reply if callback instanceof Array
          callback
        else
          callback args...
  _omelette
