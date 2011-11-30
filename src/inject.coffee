###
# Inject: Dependency Awesomeness #

Some sample ways to use inject...
    var foo = require("moduleName");
    require.ensure(["moduleOne", "moduleTwo", "moduleThree"], function(require, exports, module) {
      var foo = require("moduleOne");
    })

Configuring Inject
  require.setModuleRoot("http://example.com/path/to/js/root")
  require.setCrossDomain("http://local.example.com/path/to/relay.html", "http://remote.example.com/path/to/relay.html")
  require.manifest({
    moduleName: "http://local.example.com/path/to/module"
  }, [weight])
  require.manifest(function(path) {
  
  }, [weight])
  require.run("appName")

For more details, check out the README or github: https://github.com/Jakobo/inject
###

#
# Conventions and syntax for inject() for contributions
# 
# CoffeeScript @ 2 spaces indent
# 
# Parentheses () required at all times except:
# * Statement is single line, single argument: someValue.push pushableItem
# * Statement is single line, last argument is a callback: someAsyncFunction argOne, argTwo, (cbOne, cbTwo) ->
# 
# Over Comment
#
# Always run "cake build" and make sure it compiles. Testing is also a bonus
#

###
Constants and Registries used
###
undef = undef                       # undefined
schemaVersion = 1                   # version of inject()'s localstorage schema
context = this                      # context is our local scope. Should be "window"
pauseRequired = false               # can we run immediately? when using iframe transport, the answer is no
MODULE_ROOT = null
FILE_EXPIRES = 1440
XD_INJECT = null
XD_XHR = null
_db =                               # internal database of modules and transactions
  moduleRegistry: {}                # a registry of modules that have been loaded
  transactionRegistry: {}           # a registry of transaction ids and what modules were associated
  transactionRegistryCounter: 0     # a unique id for transactionRegistry
  loadQueue: []
  rulesQueue: []
xDomainRpc = null                   # a cross domain RPC object (Porthole)
fileStorageToken = "FILEDB"         # a storagetoken identifier we use (lscache)
fileStore = "Inject FileStorage"    # file store to use
namespace = "Inject"                # the namespace for inject() that is publicly reachable
userModules = {}                    # any mappings for module => handling defined by the user
jsSuffix = /.*?\.js$/               # Regex for identifying things that end in *.js
hostPrefixRegex = /^https?:\/\//    # prefixes for URLs that begin with http/https
hostSuffixRegex = /^(.*?)(\/.*|$)/  # suffix for URLs used to capture everything up to / or the end of the string
iframeName = "injectProxy"          # the name for the iframe proxy created (Porthole)
requireRegex = ///                  # a regex for capturing the require() statements inside of included code
  require[\s]*\([\s]*                 # followed by require, a whitespace character 0+, and an opening ( then more whitespace
  (?:"|')                             # followed by a quote
  ([\w/\.\:]+?)                       # (1) capture word characters, forward slashes, dots, and colons (at least one)
  (?:'|")                             # followed by a quote
  [\s]*\)                             # followed by whitespace, and then a closing ) that ends the require() call
  ///gm
responseSlicer = ///                # a regular expression for slicing a response from iframe communication into its parts
  ^(.+?)[\s]                          # (1) Begins with anything up to a space
  (.+?)[\s]                           # (2) Continues with anything up to a space
  (.+?)[\s]                           # (3) Continues with anything up to a space
  ([\w\W]+)$                          # (4) Any text up until the end of the string
  ///m                                # Supports multiline expressions

###
CommonJS wrappers for a header and footer
these bookend the included code and insulate the scope so that it doesn't impact inject()
or anything else.
this helps secure module bleeding
###
commonJSHeader = '''
with (window) {
  (function() {
    var module = {}, exports = {}, require = __INJECT_NS__.require, exe = null;
    module.id = "__MODULE_ID__";
    module.uri = "__MODULE_URI__";
    module.exports = exports;
    module.setExports = function(xobj) {
      for (var name in module.exports) {
        if (module.exports.hasOwnProperty(name)) {
          throw new Error("module.setExports() failed: Module Exports has already been defined");
        }
      }
      module.exports = xobj;
      return module.exports;
    }
    exe = function(module, exports, require) {
      __POINTCUT_BEFORE__
'''
commonJSFooter = '''
      __POINTCUT_AFTER__
    };
    exe.call(module, module, exports, require);
    return module.exports;
  })();
}
'''

# ### This section is the getters and setters for the internal database
# ### do not manipulate the db{} object directly
# ##########
# {} added for folding in TextMate
db = {
  module:
    create: (moduleId) ->
      registry = _db.moduleRegistry
      if !registry[moduleId]
        registry[moduleId] = {
          exports: null
          path: null
          file: null
          loading: false
          rulesApplied: false
          transactions: []
          exec: null
          pointcuts:
            before: []
            after: []
        }
    getExports: (moduleId) ->
      registry = _db.moduleRegistry
      if registry[moduleId]?.exports then return registry[moduleId].exports
      if registry[moduleId]?.exec
        registry[moduleId].exec()
        registry[moduleId].exec = null
        return registry[moduleId].exports
      return false
    setExports: (moduleId, exports) ->
      registry = _db.moduleRegistry
      db.module.create(moduleId)
      registry[moduleId].exports = exports
    getPointcuts: (moduleId) ->
      registry = _db.moduleRegistry
      if registry[moduleId]?.pointcuts then return registry[moduleId].pointcuts
    setPointcuts: (moduleId, pointcuts) ->
      registry = _db.moduleRegistry
      db.module.create(moduleId)
      registry[moduleId].pointcuts = pointcuts
    getRulesApplied: (moduleId) ->
      registry = _db.moduleRegistry
      if registry[moduleId]?.rulesApplied then return registry[moduleId].rulesApplied else return false
    setRulesApplied: (moduleId, rulesApplied) ->
      registry = _db.moduleRegistry
      db.module.create(moduleId)
      registry[moduleId].rulesApplied = rulesApplied
    getPath: (moduleId) ->
      registry = _db.moduleRegistry
      if registry[moduleId]?.path then return registry[moduleId].path else return false
    setPath: (moduleId, path) ->
      registry = _db.moduleRegistry
      db.module.create(moduleId)
      registry[moduleId].path = path
    getFile: (moduleId) ->
      registry = _db.moduleRegistry
      path = db.module.getPath(moduleId)
      token = "#{fileStorageToken}#{schemaVersion}#{path}"
      if registry[moduleId]?.file then return registry[moduleId].file
      file = lscache.get(token)
      if file and typeof(file) is "string" and file.length
        db.module.setFile(moduleId, file)
        return file
      return false
    setFile: (moduleId, file) ->
      registry = _db.moduleRegistry
      db.module.create(moduleId)
      registry[moduleId].file = file
      path = db.module.getPath(moduleId)
      token = "#{fileStorageToken}#{schemaVersion}#{path}"
      lscache.set(token, file, FILE_EXPIRES)
    clearAllFiles: () ->
      registry = _db.moduleRegistry
      for own moduleId, data of registry
        data.file = null
        data.loading = false
    getTransactions: (moduleId) ->
      registry = _db.moduleRegistry
      if registry[moduleId]?.transactions then return registry[moduleId].transactions else return false
    addTransaction: (moduleId, txnId) ->
      registry = _db.moduleRegistry
      db.module.create(moduleId)
      registry[moduleId].transactions.push(txnId)
    removeTransaction: (moduleId, txnId) ->
      registry = _db.moduleRegistry
      db.module.create(moduleId)
      newTransactions = []
      for testTxnId of registry[moduleId].transactions
        if testTxnId isnt txnId then newTransactions.push(testTxnId)
      registry[moduleId].transactions = newTransactions
    getLoading: (moduleId) ->
      registry = _db.moduleRegistry
      if registry[moduleId]?.loading then return registry[moduleId].loading else return false
    setLoading: (moduleId, loading) ->
      registry = _db.moduleRegistry
      db.module.create(moduleId)
      registry[moduleId].loading = loading
  txn:
    create: () ->
      registry = _db.transactionRegistry
      counter = "txn_#{_db.transactionRegistryCounter++}"
      registry[counter] = {
        callback: null
        modules: null
      }
      return counter
    setCallback: (txnId, callback) ->
      registry = _db.transactionRegistry
      registry[txnId].callback = callback
    getCallback: (txnId) ->
      registry = _db.transactionRegistry
      return registry[txnId].callback or ()->
    setModules: (txnId, modules) ->
      registry = _db.transactionRegistry
      registry[txnId].modules = modules
    getModules: (txnId) ->
      registry = _db.transactionRegistry
      return registry[txnId].modules or []
    delete: (txnId) ->
      registry = _db.transactionRegistry
      registry[txnId] = undef
      delete registry[txnId]
  queue:
    load:
      add: (item) ->
        _db.loadQueue.push(item)
      get: () ->
        return _db.loadQueue
    rules:
      add: (item) ->
        _db.rulesQueue.push(item)
        _db.rulesQueueDirty = true
      get: () ->
        if _db.rulesQueueDirty
          _db.rulesQueueDirty = false
          _db.rulesQueue.sort (a, b) ->
            return b.weight - a.weight
        return _db.rulesQueue
}
# ##########
# ### End getter/setter db section

setUserModules = (modl) ->
  ###
  ## setUserModules(modl) ##
  _internal_ Set the collection of user defined modules
  ###
  userModules = modl 

clearFileRegistry = (version = schemaVersion) ->
  ###
  ## clearFileRegistry(version = schemaVersion) ##
  CLEANUPOK
  _internal_ Clears the internal file registry at `version`
  clearing all local storage keys that relate to the fileStorageToken and version
  ###
  token = "#{fileStorageToken}#{version}"
  lscache.remove(lkey) for lkey,file of localStorage when lkey.indexOf(token) isnt -1 
  if version is schemaVersion then db.module.clearAllFiles()

createIframe = () ->
  ###
  ## createIframe() ##
  _internal_ create an iframe to the XD_XHR location
  ###
  src = config?.xd?.xhr
  localSrc = config?.xd?.inject
  if !src then throw new Error("Configuration requires xd.remote to be defined")
  if !localSrc then throw new Error("Configuration requires xd.local to be defined")
  
  # trims the host down to its essential values
  trimHost = (host) ->
    host = host.replace(hostPrefixRegex, "").replace(hostSuffixRegex, "$1")
    return host
  
  try
    iframe = document.createElement("<iframe name=\"" + iframeName + "\"/>")
  catch err
    iframe = document.createElement("iframe")
  iframe.name = iframeName
  iframe.src = src+"#xhr"
  iframe.style.width = iframe.style.height = "1px"
  iframe.style.right = iframe.style.bottom = "0px"
  iframe.style.position = "absolute"
  iframe.id = iframeName
  document.body.insertBefore(iframe, document.body.firstChild)
  
  # Create a proxy window to send to and receive message from the guest iframe
  xDomainRpc = new Porthole.WindowProxy(XD_XHR+"#xhr", iframeName);
  xDomainRpc.addEventListener (event) ->
    if trimHost(event.origin) isnt trimHost(XD_XHR) then return
    
    # Ready init
    if event.data is "READY"
      xDomainRpc.postMessage("READYREADY")
      pauseRequired = false
      item() for item in loadQueue
      return
    
    pieces = event.data.match(responseSlicer)
    onModuleLoad(pieces[1], pieces[2], pieces[3], pieces[4])

getFormattedPointcuts = (moduleId) ->
  ###
  ## getFormattedPointcuts(moduleId) ##
  _internal_ get the [pointcuts](http://en.wikipedia.org/wiki/Pointcut) for a module if
  specified
  ###
  cuts = db.module.getPointcuts(moduleId)
  beforeCut = [";"]
  afterCut = [";"]
  
  for cut in cuts.before
    beforeCut.push(cut.toString().match(/.*?\{([\w\W]*)\}/m)[1])
  for cut in cuts.after
    afterCut.push(cut.toString().match(/.*?\{([\w\W]*)\}/m)[1])
  
  beforeCut.push(";")
  afterCut.push(";")
  return {
    before: beforeCut.join(";\n")
    after: afterCut.join(";\n")
  }
  
  noop = () -> return
  pointcuts =
    before: noop
    after: noop
  if !userModules[module] then return pointcuts
  definition = userModules[module]
  
  for cut, fn of pointcuts
    if definition[cut] then pointcuts[cut] = definition[cut]
  
  return pointcuts


loadModules = (modList, callback) ->
  ###
  ## loadModules(modList, callback) ##
  _internal_ load a collection of modules in modList, and once they have all loaded, execute the callback cb
  ###
  
  # shortcut. If modList is undefined, then call the callback
  if modList.length is 0 then return callback.apply(context, [])
  
  # 1. create transaction
  # 2. make a request in paralell to load everything
  # 3. let onLoad callbacks resolve per transaction
  txnId = db.txn.create()
  missingModules = []
  foundModules = []
  for module in modList
    db.module.addTransaction(module, txnId)
    if !db.module.getExports(module) then missingModules.push(module) else foundModules.push(module)
  
  # check: if no missing modules, we are okay to run the callback
  if missingModules.length is 0 then return callback.apply(context, foundModules)
  
  # we were unable to shortcut anything. put callback into the registry for this txnId
  # store the modules associated with this txnId
  db.txn.setCallback(txnId, callback)
  db.txn.setModules(txnId, modList)
  
  # for each missing module
  # mark module as loading
  download(module) for module in missingModules

download = (moduleId) ->
  ###
  ## download(module) ##
  _internal_ download a module, and then hand off to processing
  ###
  # shortcut if already downloading, there's nothing to do.
  if db.module.getLoading() then return
  
  # flag as loading
  db.module.setLoading(moduleId, true)
  
  # apply the ruleset for this module if we haven't yet
  applyRules(moduleId) if db.module.getRulesApplied() is false
  
  # check for file
  file = db.module.getFile(moduleId)
  if file then onDownload(moduleId, file)
  
  # does not exist locally, download
  if XD_INJECT and XD_XHR
    sendToIframe(moduleId, onDownload)
  else
    sendToXhr(moduleId, onDownload)

applyRules = (moduleId) ->
  ###
  ## applyRules(moduleId) ##
  _internal_ normalize the path based on the module collection or any functions
  associated with its identifier
  ###
  workingPath = moduleId
  pointcuts =
    before: []
    after: []
  
  for rule in db.queue.rules.get()
    # start with workingPath, and begin applying rules
    isMatch = if typeof(rule.key) is "string" then (rule.key.toLowerCase() is workingPath.toLowerCase()) else rule.key.test(workingPath)
    if isMatch is false then continue
    # adjust the path and store any relevant pointcuts
    workingPath = if typeof(rule.path) is "string" then rule.path else rule.path(workingPath)
    if rule?.pointcuts?.before then pointcuts.before.push(rule.pointcuts.before)
    if rule?.pointcuts?.after then pointcuts.after.push(rule.pointcuts.after)
  
  # apply global rules for all paths
  if workingPath.indexOf("/") isnt 0
    if typeof(MODULE_ROOT) is "undefined" then throw new Error("Module Root must be defined")  
    else if typeof(MODULE_ROOT) is "string" then workingPath = "#{MODULE_ROOT}#{workingPath}"
    else if typeof(MODULE_ROOT) is "function" then workingPath = MODULE_ROOT(workingPath)
  if !jsSuffix.test(workingPath) then workingPath = "#{workingPath}.js"
  
  db.module.setPath(moduleId, workingPath)
  db.module.setPointcuts(moduleId, pointcuts)
  db.module.setRulesApplied(moduleId, true)


onDownload = (moduleId, file) ->
  # before we go any further, store these file contents in the db
  db.module.setFile(moduleId, file)
  
  # get transactions for this module
  for txnId in db.module.getTransactions(moduleId)
    ready = true
    modules = []
    for txnModuleId in db.txn.getModules(txnId)
      if ready is false then break
      
      # 1. attempt to get the exports (already compiled elsewhere)
      exports = db.module.getExports(txnModuleId)
      if exports isnt false
        modules.push(exports)
        continue
      
      # 2. if we are in "ready" (no failures yet) and there is a file
      # but we just haven't ran it yet, then execute the file,
      # capture the exports, and continue
      # todo: does this repeat multiple times?
      if ready and db.module.getFile(txnModuleId)
        executeFile(txnModuleId)
        exports = db.module.getExports(txnModuleId)
        modules.push(exports)
        continue
      
      # 3. we did not have the module, or the file
      # remove the ready state. That means nobody else will run
      ready = false
    
    # if we are ready, then modules[] contains the required calls
    # first, clean up the transactions, then
    # we can execute the callback associated with this txnId
    callback = db.txn.getCallback(txnId)
    for txnModuleId in db.txn.getModules(txnId)
      db.module.removeTransaction(txnModuleId, txnId)
    db.txn.delete(txnId)
    callback.apply(context, modules)

executeFile = (moduleId) ->
  ###
  ## executeFile(moduleId) ##
  _internal_ attempts to execute a file with a CommonJS scope
  and store the exports
  ###
  cuts = getFormattedPointcuts(moduleId)
  path = db.module.getPath(moduleId)
  text = db.module.getFile(moduleId)
  header = commonJSHeader.replace(/__MODULE_ID__/g, moduleId)
                         .replace(/__MODULE_URI__/g, path)
                         .replace(/__INJECT_NS__/g, namespace)
                         .replace(/__POINTCUT_BEFORE__/g, cuts.before)
  footer = commonJSFooter.replace(/__POINTCUT_AFTER__/g, cuts.after)
  runCmd = "#{header}\n#{text}\n#{footer}\n//@ sourceURL=#{path}"
  
  # find all require statements
  requires = []
  requires.push(RegExp.$1) while requireRegex.exec(db.module.getFile(moduleId))

  execModule = () ->
    # attempt to eval() the module
    try
      exports = context.eval(runCmd)
    catch err
      throw err
    # save exports
    db.module.setExports(moduleId, exports)

  if requires.length > 0
    loadModules(requires, execModule)
  else
    execModule()

sendToXhr = (moduleId, callback) ->
  ###
  ## sendToXhr(moduleId, callback) ##
  CLEANUPOK
  _internal_ request a module at path using xmlHttpRequest. On retrieval, fire off cb
  ###
  path = db.module.getPath(moduleId)
  xhr = getXHR()
  xhr.open("GET", path)
  xhr.onreadystatechange = () ->
    if xhr.readyState == 4 and xhr.status == 200 then callback.call(context, moduleId, xhr.responseText)
  xhr.send(null)

sendToIframe = (moduleId, callback) ->
  ###
  ## sendToIframe(txId, module, path, cb) ##
  CLEANUPOK
  _internal_ request a module at path using Porthole + iframe. On retrieval, the cb will be fired
  ###
  path = db.module.getPath(moduleId)
  xDomainRpc.postMessage("#{moduleId} #{path}")

getXHR = () ->
  ###
  ## getXHR() ##
  CLEANUPOK
  _internal_ get an XMLHttpRequest object
  ###
  xmlhttp = false
  if typeof XMLHttpRequest isnt "undefined"
    try
      xmlhttp = new XMLHttpRequest()
    catch errorWin
      xmlhttp = false
  if !xmlhttp and typeof window.createRequest isnt "undefined"
    try
      xmlhttp = new window.createRequest()
    catch errorCr
      xmlhttp = false
  if !xmlhttp
    try
      xmlhttp = new ActiveXObject("Msxml2.XMLHTTP")
    catch msErrOne
      try
        xmlhttp = new ActiveXObject("Microsoft.XMLHTTP")
      catch msErrTwo
        xmlhttp = false
  if !xmlhttp then throw new Error("Could not create an xmlHttpRequest Object")
  return xmlhttp

###
Main Payloads: require, require.ensure, etc
###
require = (moduleId) ->
  ###
  ## require(moduleId) ##
  CLEANUPOK
  Return the value of a module. This is a synchronous call, meaning the module needs
  to have already been loaded. If you are unsure about the module's existence, you
  should be using require.ensure() instead. For modules beyond the first tier, their
  shallow dependencies are resolved and block, so there is no need for require.ensure()
  beyond the topmost level.
  ###
  mod = db.module.getExports(moduleId)
  if mod is false then throw new Error("#{moduleId} not loaded")
  return mod

require.ensure = (moduleList, callback) ->
  ###
  ## require.ensure(moduleList, callback) ##
  CLEANUPOK
  Ensure the modules in moduleList (array) are loaded, and then execute callback
  (function). Use this instead of require() when you need to load shallow dependencies
  first.
  ###
  # init the iframe if required
  if XD_XHR? and !xDomainRpc and !pauseRequired
    createIframe()
    pauseRequired = true
  
  ensureExecutionCallback = () ->
    module = {}
    exports = {}
    module.exports = exports
    callback.call(context, require, module, exports)

  # our default behavior. Load everything
  # then, once everything says its loaded, call the callback
  run = () ->
    loadModules(moduleList, ensureExecutionCallback)
  if pauseRequired then db.queue.load.add(run)
  else run()

require.setModuleRoot = (root) ->
  ###
  ## require.setModuleRoot(root) ##
  CLEANUPOK
  set the base path for including your modules. This is used as the default if no
  items in the manifest can be located.
  
  Optionally, you can set root to a function. The return value of that function will
  be used instead. This can allow for very complex module configurations and branching
  with multiple CDNs such as in a complex production environment.
  ###
  if typeof(root) is "string" and root.lastIndexOf("/") isnt root.length then root = "#{root}/"
  MODULE_ROOT = root

require.setExpires = (expires) ->
  ###
  ## require.setExpires(expires) ##
  CLEANUPOK
  Set the time in seconds that files will persist in localStorage. Setting to 0 will disable
  localstorage caching.
  ###
  FILE_EXPIRES = expires

require.setCrossDomain = (local, remote) ->
  ###
  ## require.setCrossDomain(local, remote) ##
  CLEANUPOK
  Set a pair of URLs to relay files. You must have two relay files in your cross domain setup:
  
  * one relay file (local) on the same domain as the page hosting Inject
  * one relay file (remote) on the domain where you are hosting your root from setModuleRoot()
  
  The same require.setCrossDomain statement should be added to BOTH your relay.html files.
  ###
  XD_INJECT = local
  XD_XHR = remote

require.clearCache = (version) ->
  ###
  ## require.clearCache(version) ##
  CLEANUPOK
  Remove the localStorage class at version. If no version is specified, the entire cache is cleared.
  ###
  clearFileRegistry(version)

require.manifest = (manifest) ->
  ###
  ## require.manifest(manifest) ##
  CLEANUPOK
  Provide a custom manifest for Inject. This maps module names to file paths, adds pointcuts, and more.
  The key is always the module name, and then inside of that key can be either
  
  * a String (the path that will be used for resolving that module)
  * an Object containing
  ** path (String or Function) a path to use for the module, behaves like setModuleRoot()
  ** pointcuts (Object) a set of Aspect Oriented functions to run before and after the function.
  
  The pointcuts are a unique solution that allows you to require() things like jQuery. A pointcut could,
  for example add an after() method which sets exports.$ to jQuery.noConflict(). This would restore the
  window to its unpoluted state and make jQuery actionable as a commonJS module without having to alter
  the original library.
  ###
  throw new Error("TODO: Convert to addRule commands")

require.addRule = (match, weight = null, ruleSet = null) ->
  ###
  TODO DOC
  CLEANUPOK
  ###
  if ruleSet is null
    # weight (optional) omitted
    ruleSet = weight
    weight = rules.length
  if typeof(ruleSet) is "string"
    usePath = ruleSet
    ruleSet =
      path: usePath
  db.queue.rules.add({
    key: match
    weight: weight
    pointcuts: ruleSet.pointcuts or null
    path: ruleSet.path or null
  })

require.run = (moduleId) ->
  ###
  ## TODO require.run(moduleId) ##
  Execute the specified moduleId. This runs an ensure() to make sure the module has been loaded, and then
  execute it.
  ###

define = (moduleId, deps, callback) ->
  ###
  ## define(moduleId, deps, callback) ##
  Define a module with moduleId, run require.ensure to make sure all dependency modules have been loaded, and then
  apply the callback function with an array of dependency module objects, add the callback return and moduleId into
  moduleRegistry list.
  ###
  # Allow for anonymous functions, adjust args appropriately
  if typeof(moduleId) isnt "string"
    callback = deps
    deps = moduleId
    moduleId = null

  # This module have no dependencies
  if Object.prototype.toString.call(deps) isnt "[object Array]"
    callback = deps
    deps = []

  # Strip out 'require', 'exports', 'module' in deps array for require.ensure
  strippedDeps = []
  for dep in deps
    if dep isnt "exports" and dep isnt "require" and dep isnt "module" then strippedDeps.push(dep)

  require.ensure(strippedDeps, (require, module, exports) ->
    # already defined: require, module, exports
    # create an array with all dependency modules object
    args = []
    for dep in deps
      switch dep
        when "require" then args.push(require)
        when "exports" then args.push(exports)
        when "module" then args.push(module)
        else args.push(require(dep))

    # if callback is an object, save it to exports
    # if callback is a function, apply it with args, save the return object to exports
    if typeof(callback) is 'function'
      returnValue = callback.apply(context, args);
      count = 0
      count++ for own item in module.exports
      exports = returnValue if count is 0 and typeof(returnValue) isnt "undefined"
    else if typeof(callback) is 'object'
      exports = callback

    # save moduleId, exports into module list
    # we only save modules with an ID
    if moduleId then db.module.setExports(moduleId, exports);
  )

# To allow a clear indicator that a global define function conforms to the AMD API
define.amd =
  jQuery: true # jQuery requires explicitly defining inside of define.amd

# set context.require to the main inject object
# set context.define to the main inject object
# set an alternate interface in Inject in case things get clobbered
context.require = require
context.define = define
context.Inject = {
  require: require,
  define: define,
  debug: () ->
    console?.dir(_db)
}

###
Porthole
###
Porthole = null
`
Porthole="undefined"==typeof Porthole||!Porthole?{}:Porthole;Porthole={trace:function(){},error:function(a){try{console.error("Porthole: "+a)}catch(b){}},WindowProxy:function(){}};Porthole.WindowProxy.prototype={postMessage:function(){},addEventListener:function(){},removeEventListener:function(){}};
Porthole.WindowProxyLegacy=function(a,b){void 0===b&&(b="");this.targetWindowName=b;this.eventListeners=[];this.origin=window.location.protocol+"//"+window.location.host;null!==a?(this.proxyIFrameName=this.targetWindowName+"ProxyIFrame",this.proxyIFrameLocation=a,this.proxyIFrameElement=this.createIFrameProxy()):this.proxyIFrameElement=null};
Porthole.WindowProxyLegacy.prototype={getTargetWindowName:function(){return this.targetWindowName},getOrigin:function(){return this.origin},createIFrameProxy:function(){var a=document.createElement("iframe");a.setAttribute("id",this.proxyIFrameName);a.setAttribute("name",this.proxyIFrameName);a.setAttribute("src",this.proxyIFrameLocation);a.setAttribute("frameBorder","1");a.setAttribute("scrolling","auto");a.setAttribute("width",30);a.setAttribute("height",30);a.setAttribute("style","position: absolute; left: -100px; top:0px;");
a.style.setAttribute&&a.style.setAttribute("cssText","position: absolute; left: -100px; top:0px;");document.body.appendChild(a);return a},postMessage:function(a,b){void 0===b&&(b="*");null===this.proxyIFrameElement?Porthole.error("Can't send message because no proxy url was passed in the constructor"):(sourceWindowName=window.name,this.proxyIFrameElement.setAttribute("src",this.proxyIFrameLocation+"#"+a+"&sourceOrigin="+escape(this.getOrigin())+"&targetOrigin="+escape(b)+"&sourceWindowName="+sourceWindowName+
"&targetWindowName="+this.targetWindowName),this.proxyIFrameElement.height=50<this.proxyIFrameElement.height?50:100)},addEventListener:function(a){this.eventListeners.push(a);return a},removeEventListener:function(a){try{this.eventListeners.splice(this.eventListeners.indexOf(a),1)}catch(b){this.eventListeners=[],Porthole.error(b)}},dispatchEvent:function(a){for(var b=0;b<this.eventListeners.length;b++)try{this.eventListeners[b](a)}catch(c){Porthole.error("Exception trying to call back listener: "+
c)}}};Porthole.WindowProxyHTML5=function(a,b){void 0===b&&(b="");this.targetWindowName=b};
Porthole.WindowProxyHTML5.prototype={postMessage:function(a,b){void 0===b&&(b="*");targetWindow=""===this.targetWindowName?top:parent.frames[this.targetWindowName];targetWindow.postMessage(a,b)},addEventListener:function(a){window.addEventListener("message",a,!1);return a},removeEventListener:function(a){window.removeEventListener("message",a,!1)},dispatchEvent:function(a){var b=document.createEvent("MessageEvent");b.initMessageEvent("message",!0,!0,a.data,a.origin,1,window,null);window.dispatchEvent(b)}};
"function"!=typeof window.postMessage?(Porthole.trace("Using legacy browser support"),Porthole.WindowProxy=Porthole.WindowProxyLegacy,Porthole.WindowProxy.prototype=Porthole.WindowProxyLegacy.prototype):(Porthole.trace("Using built-in browser support"),Porthole.WindowProxy=Porthole.WindowProxyHTML5,Porthole.WindowProxy.prototype=Porthole.WindowProxyHTML5.prototype);
Porthole.WindowProxy.splitMessageParameters=function(a){if("undefined"==typeof a||null===a)return null;var b=[],a=a.split(/&/),c;for(c in a){var d=a[c].split("=");b[d[0]]="undefined"==typeof d[1]?"":d[1]}return b};Porthole.MessageEvent=function(a,b,c){this.data=a;this.origin=b;this.source=c};
Porthole.WindowProxyDispatcher={forwardMessageEvent:function(a){a=document.location.hash;if(0<a.length){a=a.substr(1);m=Porthole.WindowProxyDispatcher.parseMessage(a);targetWindow=""===m.targetWindowName?top:parent.frames[m.targetWindowName];var b=Porthole.WindowProxyDispatcher.findWindowProxyObjectInWindow(targetWindow,m.sourceWindowName);b?b.origin==m.targetOrigin||"*"==m.targetOrigin?(a=new Porthole.MessageEvent(m.data,m.sourceOrigin,b),b.dispatchEvent(a)):Porthole.error("Target origin "+b.origin+
" does not match desired target of "+m.targetOrigin):Porthole.error("Could not find window proxy object on the target window")}},parseMessage:function(a){if("undefined"==typeof a||null===a)return null;params=Porthole.WindowProxy.splitMessageParameters(a);var b={targetOrigin:"",sourceOrigin:"",sourceWindowName:"",data:""};b.targetOrigin=unescape(params.targetOrigin);b.sourceOrigin=unescape(params.sourceOrigin);b.sourceWindowName=unescape(params.sourceWindowName);b.targetWindowName=unescape(params.targetWindowName);
a=a.split(/&/);if(3<a.length)a.pop(),a.pop(),a.pop(),a.pop(),b.data=a.join("&");return b},findWindowProxyObjectInWindow:function(a,b){a.RuntimeObject&&(a=a.RuntimeObject());if(a)for(var c in a)try{if(null!==a[c]&&"object"==typeof a[c]&&a[c]instanceof a.Porthole.WindowProxy&&a[c].getTargetWindowName()==b)return a[c]}catch(d){}return null},start:function(){window.addEventListener?window.addEventListener("resize",Porthole.WindowProxyDispatcher.forwardMessageEvent,!1):document.body.attachEvent?window.attachEvent("onresize",
Porthole.WindowProxyDispatcher.forwardMessageEvent):Porthole.error("Can't attach resize event")}};
`

###
lscache library
###
lscache=null
`
var lscache=function(){function g(){return Math.floor((new Date).getTime()/6E4)}function l(a,b,f){function o(){try{localStorage.setItem(a+c,g()),0<f?(localStorage.setItem(a+d,g()+f),localStorage.setItem(a,b)):0>f||0===f?(localStorage.removeItem(a+c),localStorage.removeItem(a+d),localStorage.removeItem(a)):localStorage.setItem(a,b)}catch(h){if("QUOTA_EXCEEDED_ERR"===h.name||"NS_ERROR_DOM_QUOTA_REACHED"==h.name){if(0===i.length&&!m)return localStorage.removeItem(a+c),localStorage.removeItem(a+d),localStorage.removeItem(a),
!1;m&&(m=!1);if(!e){for(var n=0,l=localStorage.length;n<l;n++)if(j=localStorage.key(n),-1<j.indexOf(c)){var p=j.split(c)[0];i.push({key:p,touched:parseInt(localStorage[j],10)})}i.sort(function(a,b){return a.touched-b.touched})}if(k=i.shift())localStorage.removeItem(k.key+c),localStorage.removeItem(k.key+d),localStorage.removeItem(k.key);o()}}}var e=!1,m=!0,i=[],j,k;o()}var d="-EXP",c="-LRU",e;try{e=!!localStorage.getItem}catch(q){e=!1}var h=null!=window.JSON;return{set:function(a,b,c){if(e){if("string"!=
typeof b){if(!h)return;try{b=JSON.stringify(b)}catch(d){return}}l(a,b,c)}},get:function(a){function b(a){if(h)try{return JSON.parse(localStorage.getItem(a))}catch(b){return localStorage.getItem(a)}else return localStorage.getItem(a)}if(!e)return null;if(localStorage.getItem(a+d)){var f=parseInt(localStorage.getItem(a+d),10);if(g()>=f)localStorage.removeItem(a),localStorage.removeItem(a+d),localStorage.removeItem(a+c);else return localStorage.setItem(a+c,g()),b(a)}else if(localStorage.getItem(a))return localStorage.setItem(a+
c,g()),b(a);return null},remove:function(a){if(!e)return null;localStorage.removeItem(a);localStorage.removeItem(a+d);localStorage.removeItem(a+c)}}}();
`