#     imgflo - Flowhub.io Image-processing runtime
#     (c) 2014 The Grid
#     imgflo may be freely distributed under the MIT license

server = require '../src/server'
utils = require './utils'
chai = require 'chai'
yaml = require 'js-yaml'
request = require 'request'
async = require 'async'
statistics = require 'simple-statistics'

http = require 'http'
fs = require 'fs'
path = require 'path'
url = require 'url'

# TODO:
#
# 1, 10, 100 concurrent requests of different (unprocessed) graphs
# 10, 100, 1000, 10k concurrent requests of cached graphs ^10
# 50, 100, 200, 400, 800, 1600 px width/height ^2
# lowest series indicating latency lower boundary, slope indicating scaling
# will need to do multiple rounds on each test series to get enough data
# add a way to clean cache between each round?
#
# Measure processing time per request. Store raw data as .json
# URL + time(s)
# Build statistics, evaluate if acceptable
# mean+median latency, quartiles, std-dev, percentage above soft+hard limit
# differences between request sizes, evaluate scaleability
# should have confidence tests
# very huge timeout, like 5 mins?
# only run if a flag is set (opt-in)
# ideally be able to directly on server, to evaluate how much network latency is
# also run with a mix of local input images and remote
# Verify correctness of images against eachohter. SHA sum based on first

urlbase = process.env.IMGFLO_TESTS_TARGET
urlbase = 'localhost:8888' if not urlbase
port = (urlbase.split ':')[1]
verbose = process.env.IMGFLO_TESTS_VERBOSE?
startServer = (urlbase.indexOf 'localhost') == 0
itSkipRemote = if not startServer then it.skip else it
describeSkipPerformance = if process.env.IMGFLO_TESTS_PERFORMANCE? then describe else describe.skip

requestRecordTime = (reqUrl, callback) ->
    startTime = process.hrtime()
    req = request reqUrl, (err, response) ->
        timeDiff = process.hrtime(startTime)
        timeDiffMs = timeDiff[0]*1000 + timeDiff[1]/1000000
        return callback err, timeDiffMs if err
        return callback null, timeDiffMs

    return req

createRequests = (number) ->
    f = (n) ->
        p =
            input: 'demo/gradient-black-white.png'
        utils.formatRequest urlbase, 'gradientmap', p
    return (f(n) for n in [0...number])

# End-to-end stress-tests of image processing server, particularly performance
describeSkipPerformance 'Stress', ->
    s = null
    l = null

    before ->
        wd = './stressteststemp'
        if fs.existsSync wd
            for f in fs.readdirSync wd
                fs.unlinkSync path.join wd, f
        if startServer
            s = new server.Server wd, null, null, verbose
            l = new utils.LogHandler s
            s.listen port
    after ->
        s.close() if startServer


    describe "Concurrent requests of cached graphs", ->
        results = null
        requestUrls = createRequests 1000

        it 'generating cache', (done) ->
            cacheUrl = requestUrls[0]
            requestRecordTime cacheUrl, (err, res) ->
                chai.expect(err).to.not.exist;
                done()

        it 'executing test', (done) ->
            @timeout 5*60*1000

            limit = 100
            async.mapLimit requestUrls, limit, requestRecordTime, (err, res) ->
                results = res
                chai.expect(err).to.not.exist
                done()

        it 'do statistics', (done) ->
            console.log statistics.mean(results)
            done()

