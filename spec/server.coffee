#     imgflo-server - Image-processing server
#     (c) 2014 The Grid
#     imgflo-server may be freely distributed under the MIT license

# TODO: add more tests
# processing new (200 or 301 to image/ ? )
#   works - with remote HTTP URL
#   w - remote HTTP with .PNG
#   w - remote HTTP with .JPG
#   w - remote HTTP without extension, content type image/png
#   w - remote HTTP without extension, .. image/jpeg
#   w - HTTP url with redirect
#
#   ? - content-type different from extension
#
#   maybe; w - content type application/x-octet-stream, but valid JPG/PNG
#
#   error - unsupported content type (449)
#   e - input parameter missing
#   e - url gives 404 (404)
#   e - url does not load for other reasons (504)
#   e - invalid parameter value (422?)
#      -- too big/small numbers
#   e - valid ext,content-type, but invalid image
#
#   w - get cached / previously processed image (301)
#       .. test all the processing cases
#
# stress
# works - multiple requests at same time
#
# error - too many requests (429?)
# e - too big file download, bytes: (413)
# e - too large image, width/height (413)
#
# adverse conditions
# e - compression explosion exploits
# e - code-in-metadata-chunks
# e - input url points to localhost (local to server)
# e - infinetely/circular redirects
# e - chained/recursive processing requests
#
# introspection
#  w - list available graphs, and their properties

server = require '../src/server'
utils = require './utils'
http = require 'http'
fs = require 'fs'
path = require 'path'
url = require 'url'

chai = require 'chai'
request = require 'request'

http.globalAgent.maxSockets = Infinity # for older node.js

config = utils.getTestConfig()
startServer = (config.api_host.indexOf 'localhost') == 0
itSkipRemote = if not startServer then it.skip else it
urlbase = config.api_host # compat

cacheurl = '/cache/' if config.cache_type.indexOf('local') != -1
cacheurl = 'amazonaws.com' if config.cache_type.indexOf('s3') != -1

graph_url = (graph, props, key, secret) ->
    return utils.formatRequest config.api_host, graph, props, key, secret

describe 'Server', ->
    s = null

    before (done) ->
        utils.rmrf config.workdir
        if startServer
            s = new server.Server config
            l = new utils.LogHandler s
            s.listen config.api_host, config.api_port, done
        else
            done()
    after (done) ->
        s.close done if startServer

    describe.skip 'Get version info', ->
        info = null
        it 'returns valid data', (done) ->
            u = url.format {protocol:'http:',host: urlbase, pathname:'/version'}
            request u, (err, response, body) ->
                chai.expect(err).to.not.exist
                chai.expect(response.statusCode).to.equal 200
                info = JSON.parse body
                done()
        it 'gives NPM version', ->
            chai.expect(info.err).to.be.a 'undefined'
            chai.expect(info.npm).to.equal '0.0.3'
        it 'gives server version', ->
            chai.expect(info.server).to.be.a 'string'
        it 'gives runtime version', ->
            chai.expect(info.runtime).to.be.a 'string'
        it.skip 'gives GEGL version', ->
            chai.expect(info.gegl).to.be.a 'string'
        it.skip 'gives BABL version', ->
            chai.expect(info.babl).to.be.a 'string'

    describe 'List graphs', ->
        expected = []
        for g in fs.readdirSync './graphs'
            expected.push g.replace '.json', '' if (g.indexOf '.json') != -1
        responseData = ""
        it 'HTTP request', (done) ->
            u = url.format {protocol:'http:',host: urlbase, pathname:'/demo'}
            http.get u, (response) ->
                chai.expect(response.statusCode).to.equal 200
                response.on 'data', (chunk) ->
                    responseData += chunk.toString()
                response.on 'end', () ->
                    done()
        it 'should return all processing graphs', () ->
            d = JSON.parse responseData
            actual = Object.keys d.graphs
            chai.expect(actual).to.deep.equal expected

        it 'should not include internal msgflo graph', () ->
            g = fs.readFileSync './graphs/imgflo-server.fbp'
            chai.expect(g).to.exist
            d = JSON.parse responseData
            chai.expect(d.graphs).to.not.have.key 'imgflo-server'

    describe 'Graph request', ->
        describe 'with invalid graph parameters', ->
            u = graph_url 'gradientmap', {skeke: 299, oooor:222, input: "demo/grid-toastybob.jpg"}
            data = ""
            it 'should give HTTP 449', (done) ->
                http.get u, (response) ->
                    chai.expect(response.statusCode).to.equal 449
                    response.on 'data', (chunk) ->
                        data += chunk.toString()
                    response.on 'end', () ->
                        done()
            it 'should list valid parameters', ->
                d = JSON.parse data
                e = ['input', 'color1', 'color2', "color3", "color4", "color5",
                    "stop1", "stop2", "stop3", "stop4", "stop5", "srgb", "opacity"]
                chai.expect(Object.keys(d.inports)).to.deep.equal
        describe 'with unsupported image type', ->
            u = graph_url 'gradientmap.svg', { input: "demo/happy-kitten.svg" }
            data = ""
            it 'should give HTTP 449', (done) ->
                http.get u, (response) ->
                    chai.expect(response.statusCode).to.equal 449
                    response.on 'data', (chunk) ->
                        data += chunk.toString()
                    response.on 'end', () ->
                        done()
            it 'should list supported types', ->
                d = JSON.parse data
                chai.expect(d.supported).to.eql ['jpg', 'jpeg', 'png', null]

    describe 'Get image', ->
        u = graph_url 'crop', { height: 110, width: 130, x: 200, y: 230, input: "demo/grid-toastybob.jpg" }
        res = null
        location = null

        it 'should be created on demand', (done) ->
            @timeout 15000
            checkProcessed = (id) ->
                chai.expect(id).to.not.contain 'error'
                if id == 'serve-processed-file'
                    s.removeListener 'logevent', checkProcessed
                    done()
            s.on 'logevent', checkProcessed # NOTE: Grey-box
            http.get u, (response) ->
                res = response

        it 'should redirect to cached file', () ->
            chai.expect(res.statusCode).to.equal 301
            chai.expect(res.headers).to.contain.keys 'location'
            location = res.headers['location']
            chai.expect(location).to.contain cacheurl
        it 'redirect should end with .jpg', () ->
            chai.expect(location).to.contain '.jpg'
        it 'key should be deterministic', () ->
            basename = path.basename (url.parse location).pathname, '.jpg'
            chai.expect(basename).to.equal '41866f4ea03c094cf47d6c8c7e0c8f48b974c241'
        it 'redirect should point to created image', (done) ->
            http.get location, (response) ->
                chai.expect(response.statusCode).to.equal 200
                response.on 'data', (chunk) ->
                    fs.appendFile 'testout.png', chunk, ->
                        #
                response.on 'end', ->
                    fs.exists 'testout.png', (exists) ->
                        chai.assert exists, 'testout.png does not exist'
                        done()

    describe 'Get existing image', ->
        u = graph_url 'crop', { height: 110, width: 130, x: 200, y: 230, input: "demo/grid-toastybob.jpg" }
        response = null
        location = null

        it 'should be in cache', (done) ->
            checkProcessed = (id) ->
                chai.expect(id).to.not.contain 'error'
                if id == 'graph-in-cache'
                    s.removeListener 'logevent', checkProcessed
                    done()
            s.on 'logevent', checkProcessed
            http.get u, (res) ->
                response = res

        it 'should be a redirect', () ->
            chai.expect(response.statusCode).to.equal 301
            location = response.headers['location']
            chai.expect(location).to.contain cacheurl

        it 'should end with .jpg', () ->
            chai.expect(location).to.contain '.jpg'

    describe 'Missing authentication', ->
        u = graph_url 'crop', { height: 110, width: 130, x: 200, y: 230, input: "demo/grid-toastybob.jpg" }

        it 'should fail with a 403', (done) ->
            # Enable auth
            s.authdb = { 'ooShei0queigeeke': 'reeva9aijo1Ooj9w' }

            http.get u, (res) ->
                chai.expect(res.statusCode).to.equal 403
                done()

    describe 'Correct authentication', ->
        location = null

        p = { height: 110, width: 130, x: 200, y: 230, input: "demo/grid-toastybob.jpg" }
        u = graph_url 'crop', p, 'ooShei0queigeeke', 'reeva9aijo1Ooj9w'

        it 'request should succeed with redirect to file', (done) ->
            # Enable auth
            s.authdb = { 'ooShei0queigeeke': 'reeva9aijo1Ooj9w' }

            http.get u, (res) ->
                chai.expect(res.statusCode).to.equal 301
                location = res.headers['location']
                chai.expect(location).to.contain cacheurl
                done()
        it 'file should be same as for non-authed request', () ->
            chai.expect(location).to.be.a 'string'
            basename = path.basename (url.parse location).pathname, '.jpg'
            chai.expect(basename).to.equal '41866f4ea03c094cf47d6c8c7e0c8f48b974c241'

    describe 'Providing auth when not needed', ->
        p = { height: 110, width: 130, x: 200, y: 230, input: "demo/grid-toastybob.jpg" }
        u = graph_url 'crop', p, 'ooShei0queigeeke', 'mysecret?'

        it 'request should succeed with redirect to file', (done) ->
            # Disable auth
            s.authdb = null

            http.get u, (res) ->
                chai.expect(res.statusCode).to.equal 301
                location = res.headers['location']
                chai.expect(location).to.contain cacheurl
                done()

    describe 'Incorrect secret', ->
        p = { height: 110, width: 130, x: 200, y: 230, input: "demo/grid-toastybob.jpg" }
        u = graph_url 'crop', p, 'ooShei0queigeeke', 'mysecret?'

        it 'should fail with a 403', (done) ->
            # Enable auth
            s.authdb = { 'ooShei0queigeeke': 'reeva9aijo1Ooj9w' }

            http.get u, (res) ->
                chai.expect(res.statusCode).to.equal 403
                done()

    describe 'Invalid apikey', ->

        p = { height: 110, width: 130, x: 200, y: 230, input: "demo/grid-toastybob.jpg" }
        u = graph_url 'crop', p, 'apikey?', 'mysecret?'

        it 'should fail with a 403', (done) ->
            @timeout 5000
            # Enable auth
            s.authdb = { 'ooShei0queigeeke': 'reeva9aijo1Ooj9w' }

            http.get u, (res) ->
                chai.expect(res.statusCode).to.equal 403
                done()
