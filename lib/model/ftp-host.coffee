Host = require './host'
RemoteFile = require './remote-file'
LocalFile = require './local-file'

async = require 'async'
filesize = require 'file-size'
moment = require 'moment'
ftp = require 'ftp'
Serializable = require 'serializable'
path = require 'path'
{Emitter} = require 'emissary'
_ = require 'underscore-plus'


module.exports =
  class FtpHost extends Host
    Serializable.includeInto(this)

    Host.registerDeserializers(FtpHost)
    Emitter.includeInto(this)

    constructor: (@hostname, @directory, @username, @port, @localFiles = [], @password) ->
      super

    createRemoteFileFromListObj: (name, item) ->
      remoteFile = new RemoteFile(path.normalize((name + '/' + item.name)), false, false, filesize(item.size).human(), null, null)

      if item.type == "d"
        remoteFile.isDir = true
      else if item.type == "-"
        remoteFile.isFile = true
      else if item.type == 'l'
        # this is really a symlink but i add it as a file anyway
        remoteFile.isFile = true

      if item.rights?
        remoteFile.permissions = (@convertRWXToNumber(item.rights.user) + @convertRWXToNumber(item.rights.group) + @convertRWXToNumber(item.rights.other))

      if item.date?
        remoteFile.lastModified = moment(item.date).format("HH:MM DD/MM/YYYY")

      return remoteFile

    convertRWXToNumber: (str) ->
      toreturn = 0
      for i in str
        if i == 'r'
          toreturn += 4
        else if i == 'w'
          toreturn += 2
        else if i == 'x'
          toreturn += 1
      return toreturn.toString()


    ####################
    # Overridden methods
    getConnectionString: (connectionOptions) ->
      _.extend({
        host: @hostname,
        port: @port,
        user: @username,
        password: @password
      }, connectionOptions)

    close: (callback) ->
      @connection?.end()
      callback?(null)

    connect: (callback, connectionOptions = {}) ->
      @emit 'info', {message: "Connecting to #{@username}@#{@hostname}:#{@port}", className: 'text-info'}
      async.waterfall([
        (callback) =>
          @connection = new ftp()
          @connection.on 'error', (err) =>
            @connection.end()
            @emit 'info', {message: "Error occured when connecting to #{@username}@#{@hostname}:#{@port}", className: 'text-error'}
            callback(err)
          @connection.on 'ready', () =>
            @emit 'info', {message: "Successfully connected to #{@username}@#{@hostname}:#{@port}", className: 'text-success'}
            callback(null)
          @connection.connect(@getConnectionString(connectionOptions))
        ], (err) ->
          callback?(err)
        )

    writeFile: (file, text, callback) ->
      @emit 'info', {message: "Writing remote file #{@username}@#{@hostname}:#{@port}#{file.remoteFile.path}", className: 'text-info'}
      async.waterfall([
        (callback) =>
          if !@connection?
            @connect(callback)
          else if !@connection.connected
            @connect(callback)
          else
            callback(new Error())
        (callback) =>
          @connection.put((new Buffer(text)), file.remoteFile.path, callback)
        ], (err) =>
          if err?
            @emit('info', {message: "Error occured when writing remote file #{@username}@#{@hostname}:#{@port}#{file.remoteFile.path}", className: 'text-error'})
            console.debug err if err?
          else
            @emit('info', {message: "Successfully wrote remote file #{@username}@#{@hostname}:#{@port}#{file.remoteFile.path}", className: 'text-success'})
          @close()
          callback?(err)
        )

    getFilesMetadata: (path, callback) ->
      async.waterfall([
        (callback) =>
          @connection.list(path, callback)
        (files, callback) =>
          async.map(files, ((item, callback) => callback(null, @createRemoteFileFromListObj(path, item))), callback)
        (objects, callback) =>
          objects.push(new RemoteFile((path + "/.."), false, true, null, null, null))
          objects.push(new RemoteFile((path + "/."), false, true, null, null, null))
          if atom.config.get 'remote-edit.showHiddenFiles'
            callback(null, objects)
          else
            async.filter(objects, ((item, callback) -> item.isHidden(callback)), ((result) => callback(null, result)))
        ], (err, result) =>
          callback?(err, (result.sort (a, b) => return if a.name.toLowerCase() >= b.name.toLowerCase() then 1 else -1))
        )

    getFileData: (file, callback) ->
      @emit('info', {message: "Getting remote file #{@username}@#{@hostname}:#{@port}#{file.path}", className: 'text-info'})
      @connection.get(file.path, (err, stream) =>
        if err?
          @emit('info', {message: "Error when reading remote file #{@username}@#{@hostname}:#{@port}#{file.path}", className: 'text-error'})
          callback(err, null)
        else
          @emit('info', {message: "Successfully read remote file #{@username}@#{@hostname}:#{@port}#{file.path}", className: 'text-success'})
          stream.once('data', (chunk) ->
            callback?(null, chunk.toString('utf8'))
          )
      )

    serializeParams: ->
      {
        @hostname
        @directory
        @username
        @port
        localFiles: JSON.stringify(localFile.serialize() for localFile in @localFiles)
        @password
      }

    deserializeParams: (params) ->
      tmpArray = []
      tmpArray.push(LocalFile.deserialize(localFile, host: this)) for localFile in JSON.parse(params.localFiles)
      params.localFiles = tmpArray
      params
