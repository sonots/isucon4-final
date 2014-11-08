require 'sinatra/base'
require 'pathname'
require 'digest/sha2'
require 'hiredis'
require 'redis'
require 'redis/connection/hiredis'
require 'json'
require 'rack/request'
require_relative 'ext/rack/multipart/parser'

ADDRESSES = %w[
  10.11.54.176
  10.11.54.177
  10.11.54.178
]

$redis = []
$redis[0] = Redis.new(:driver => :hiredis, :host => ADDRESSES[0])
$redis[1] = Redis.new(:driver => :hiredis, :host => ADDRESSES[1])
$redis[2] = Redis.new(:driver => :hiredis, :host => ADDRESSES[2])

module Isucon4
  class App < Sinatra::Base
    set :public_folder, "#{__dir__}/../public"
    ADS_DIR = Pathname.new(__dir__).join('ads')
    LOG_DIR = Pathname.new(__dir__).join('logs')
    ADS_DIR.mkpath unless ADS_DIR.exist?
    LOG_DIR.mkpath unless LOG_DIR.exist?

    helpers do
      def advertiser_id
        request.env['HTTP_X_ADVERTISER_ID']
      end

      def str_hash(key)
        key.bytes.inject(&:+)
      end

      def redis(key)
        @id ||= {}
        @id[key] = str_hash(key) % 3
        $redis[@id[key]]
      end

      def ad_key(slot, id)
        "isu4:ad:#{slot}-#{id}"
      end

      def asset_key(slot, id)
        "isu4:asset:#{slot}-#{id}"
      end

      def advertiser_key(id)
        "isu4:advertiser:#{id}"
      end

      def slot_key(slot)
        "isu4:slot:#{slot}"
      end

      def next_ad_id
        redis('isu4:ad-next').incr('isu4:ad-next').to_i
      end

      def next_ad(slot)
        key = slot_key(slot)

        id = redis(key).rpoplpush(key, key)
        unless id
          return nil
        end

        ad = get_ad(slot, id)
        if ad
          ad
        else
          redis(key).lrem(key, 0, id)
          next_ad(slot)
        end
      end

      def get_ad(slot, id)
        key = ad_key(slot, id)
        ad = redis(key).hgetall(key)

        return nil if !ad || ad.empty?
        ad['impressions'] = ad['impressions'].to_i
        ad['asset'] = url("/slots/#{slot}/ads/#{id}/asset")
        ad['counter'] = url("/slots/#{slot}/ads/#{id}/count")
        ad['redirect'] = url("/slots/#{slot}/ads/#{id}/redirect")
        ad['type'] = nil if ad['type'] == ""

        ad
      end

      def decode_user_key(id)
        return {gender: :unknown, age: nil} if !id || id.empty?
        gender, age = id.split('/', 2).map(&:to_i)
        {gender: gender == 0 ? :female : :male, age: age}
      end

      def get_log(id)
        mysql = connection
        advertiser_id = id.split('/').last
        redirects = mysql.xquery('SELECT id, isuad, advertiser_id ,user_agent FROM redirects WHERE advertiser_id= ?', advertiser_id)
        #path = LOG_DIR.join(id.split('/').last)
        return {} unless redirects.nil?

        redirects.each do | data |
          {ad_id: data['id'], user: data['isuad'], agent: data['user_agent'] && !agent.empty? ? agent : :unknown}.merge(decode_user_key(data['isuad']))
        end
        #open(path, 'r') do |io|
        #  io.flock File::LOCK_SH
        #  io.read.each_line.map do |line|
        #    ad_id, user, agent = line.chomp.split(?\t,3)
        #    {ad_id: ad_id, user: user, agent: agent && !agent.empty? ? agent : :unknown}.merge(decode_user_key(user))
        #  end.group_by { |click| click[:ad_id] }
        #end
      end

      def connection
        return $mysql if $mysql
        $mysql = Mysql2::Client.new(
          :host => '203.104.111.176',
          :port => 3306,
          :username => 'root',
          :password => '',
          :database => 'isucon',
          :reconnect => true,
        )
      end
    end

    get '/' do
      Pathname.new(self.class.public_folder).join('index.html').read
    end

    post '/slots/:slot/ads' do
      unless advertiser_id
        halt 400
      end

      slot = params[:slot]
      asset = params[:asset][:tempfile]

      id = next_ad_id
      key = ad_key(slot, id)

      redis(key).hmset(
        key,
        'slot', slot,
        'id', id,
        'title', params[:title],
        'type', params[:type] || params[:asset][:type] || 'video/mp4',
        'advertiser', advertiser_id,
        'destination', params[:destination],
        'impressions', 0,
      )
      redis(asset_key(slot,id)).set(asset_key(slot,id), asset.read)
      redis(slot_key(slot)).rpush(slot_key(slot), id)
      redis(advertiser_key(advertiser_id)).sadd(advertiser_key(advertiser_id), key)

      content_type :json
      get_ad(slot, id).to_json
    end

    get '/slots/:slot/ad' do
      ad = next_ad(params[:slot])
      if ad
        redirect "/slots/#{params[:slot]}/ads/#{ad['id']}"
      else
        status 404
        content_type :json
        {error: :not_found}.to_json
      end
    end

    get '/slots/:slot/ads/:id' do
      content_type :json
      ad = get_ad(params[:slot], params[:id])
      if ad
        ad.to_json
      else
        status 404
        content_type :json
        {error: :not_found}.to_json
      end
    end

    get '/slots/:slot/ads/:id/asset' do
      ad = get_ad(params[:slot], params[:id])
      if ad
        content_type ad['type'] || 'application/octet-stream'
        key = asset_key(params[:slot],params[:id])
        data = redis(key).get(key).b

        # Chrome sends us Range request even we declines...
        range = request.env['HTTP_RANGE'] 
        case
        when !range || range.empty?
          data
        when /\Abytes=(\d+)?-(\d+)?\z/ === range
          head, tail = $1, $2
          halt 416 if !head && !tail
          head ||= 0
          tail ||= data.size-1

          head, tail = head.to_i, tail.to_i
          halt 416 if head < 0 || head >= data.size || tail < 0

          status 206
          headers 'Content-Range' => "bytes #{head}-#{tail}/#{data.size}"
          data[head.to_i..tail.to_i]
        else
          # We don't respond to multiple Range requests and non-`bytes` Range request
          halt 416
        end
      else
        status 404
        content_type :json
        {error: :not_found}.to_json
      end
    end

    # log for mysql
    post '/slots/:slot/ads/:id/count' do
      key = ad_key(params[:slot], params[:id])

      unless redis(key).exists(key)
        status 404
        content_type :json
        next {error: :not_found}.to_json
      end

      redis(key).hincrby(key, 'impressions', 1)
      #mysql = connection
      #mysql.xquery(
      #  'UPDATE impressions SET count = count + 1 WHERE key = ?',
      #  key
      #)

      status 204
    end

    # log for mysql
    get '/slots/:slot/ads/:id/redirect' do
      ad = get_ad(params[:slot], params[:id])
      unless ad
        status 404
        content_type :json
        next {error: :not_found}.to_json
      end

      mysql = connection
      mysql.xquery(
        'INSERT INTO redirects (id, isuad, advertiser_id ,user_agent) VALUES (?, ?, ?, ?)',
        ad['id'],
        ad['advertiser'].split('/').last,
        request.cookies['isuad'],
        request.user_agent,
      )

      #open(LOG_DIR.join(ad['advertiser'].split('/').last), 'a') do |io|
      #  io.flock File::LOCK_EX
      #  io.puts([ad['id'], request.cookies['isuad'], request.user_agent].join(?\t))
      #end

      redirect ad['destination']
    end

    get '/me/report' do
      if !advertiser_id || advertiser_id == ""
        halt 401
      end

      content_type :json

      {}.tap do |report|
        key = advertiser_key(advertiser_id)
        redis(key).smembers(key).each do |ad_key|
          ad = redis(ad_key).hgetall(ad_key)
          next unless ad
          ad['impressions'] = ad['impressions'].to_i

          report[ad['id']] = {ad: ad, clicks: 0, impressions: ad['impressions']}
        end

        get_log(advertiser_id).each do |ad_id, clicks|
          report[ad_id][:clicks] = clicks.size
        end
      end.to_json
    end

    get '/me/final_report' do
      if !advertiser_id || advertiser_id == ""
        halt 401
      end

      content_type :json

      {}.tap do |reports|
        key = advertiser_key(advertiser_id)
        redis(key).smembers(key).each do |ad_key|
          ad = redis(ad_key).hgetall(ad_key)
          next unless ad
          ad['impressions'] = ad['impressions'].to_i

          reports[ad['id']] = {ad: ad, clicks: 0, impressions: ad['impressions']}
        end

        logs = get_log(advertiser_id)

        reports.each do |ad_id, report|
          log = logs[ad_id] || []
          report[:clicks] = log.size

          breakdown = report[:breakdown] = {}

          breakdown[:gender] = log.group_by{ |_| _[:gender] }.map{ |k,v| [k,v.size] }.to_h
          breakdown[:agents] = log.group_by{ |_| _[:agent] }.map{ |k,v| [k,v.size] }.to_h
          breakdown[:generations] = log.group_by{ |_| _[:age] ? _[:age].to_i / 10 : :unknown }.map{ |k,v| [k,v.size] }.to_h
        end
      end.to_json
    end

    post '/initialize' do
      $redis.each do |redis|
        redis.keys('isu4:*').each_slice(1000).map do |keys|
          redis.del(*keys)
        end
      end

      LOG_DIR.children.each(&:delete)

      content_type 'text/plain'
      "OK"
    end
  end
end
