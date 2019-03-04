# "Invidious" (which is an alternative front-end to YouTube)
# Copyright (C) 2018  Omar Roth
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "digest/md5"
require "file_utils"
require "kemal"
require "openssl/hmac"
require "option_parser"
require "pg"
require "sqlite3"
require "xml"
require "yaml"
require "zip"
require "./invidious/helpers/*"
require "./invidious/*"

CONFIG   = Config.from_yaml(File.read("config/config.yml"))
HMAC_KEY = CONFIG.hmac_key || Random::Secure.hex(32)

config = CONFIG
logger = Invidious::LogHandler.new

Kemal.config.extra_options do |parser|
  parser.banner = "Usage: invidious [arguments]"
  parser.on("-t THREADS", "--crawl-threads=THREADS", "Number of threads for crawling YouTube (default: #{config.crawl_threads})") do |number|
    begin
      config.crawl_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-c THREADS", "--channel-threads=THREADS", "Number of threads for refreshing channels (default: #{config.channel_threads})") do |number|
    begin
      config.channel_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-f THREADS", "--feed-threads=THREADS", "Number of threads for refreshing feeds (default: #{config.feed_threads})") do |number|
    begin
      config.feed_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-v THREADS", "--video-threads=THREADS", "Number of threads for refreshing videos (default: #{config.video_threads})") do |number|
    begin
      config.video_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-o OUTPUT", "--output=OUTPUT", "Redirect output (default: STDOUT)") do |output|
    FileUtils.mkdir_p(File.dirname(output))
    logger = Invidious::LogHandler.new(File.open(output, mode: "a"))
  end
end

Kemal::CLI.new ARGV

YT_URL          = URI.parse("https://www.youtube.com")
REDDIT_URL      = URI.parse("https://www.reddit.com")
LOGIN_URL       = URI.parse("https://accounts.google.com")
PUBSUB_URL      = URI.parse("https://pubsubhubbub.appspot.com")
TEXTCAPTCHA_URL = URI.parse("http://textcaptcha.com/omarroth@hotmail.com.json")
CURRENT_COMMIT  = `git rev-list HEAD --max-count=1 --abbrev-commit`.strip
CURRENT_VERSION = `git describe --tags $(git rev-list --tags --max-count=1)`.strip
CURRENT_BRANCH  = `git status | head -1`.strip

LOCALES = {
  "ar"    => load_locale("ar"),
  "de"    => load_locale("de"),
  "en-US" => load_locale("en-US"),
  "eu"    => load_locale("eu"),
  "fr"    => load_locale("fr"),
  "it"    => load_locale("it"),
  "nb_NO" => load_locale("nb_NO"),
  "nl"    => load_locale("nl"),
  "pl"    => load_locale("pl"),
  "ru"    => load_locale("ru"),
}

statistics = {
  "error" => "Statistics are not availabile.",
}

decrypt_function = [] of {name: String, value: Int32}
spawn do
  update_decrypt_function do |function|
    decrypt_function = function
    sleep 1.minutes
    Fiber.yield
  end
end

proxies = PROXY_LIST

before_all do |env|
  env.response.headers["X-XSS-Protection"] = "1; mode=block;"
  env.response.headers["X-Content-Type-Options"] = "nosniff"

  locale = env.params.query["hl"]?
  locale ||= "en-US"
  env.set "locale", locale
end

# API Endpoints

get "/api/v1/stats" do |env|
  env.response.content_type = "application/json"

  if statistics["error"]?
    halt env, status_code: 500, response: statistics.to_json
  end

  if !config.statistics_enabled
    error_message = {"error" => "Statistics are not enabled."}.to_json
    halt env, status_code: 400, response: error_message
  end

  if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
    statistics.to_pretty_json
  else
    statistics.to_json
  end
end

get "/api/v1/captions/:id" do |env|
  locale = LOCALES[env.get("locale").as(String)]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]
  region = env.params.query["region"]?

  client = make_client(YT_URL)
  begin
    video = fetch_video(id, proxies, region: region)
  rescue ex : VideoRedirect
    next env.redirect "/api/v1/captions/#{ex.message}"
  rescue ex
    halt env, status_code: 500
  end

  captions = video.captions

  label = env.params.query["label"]?
  lang = env.params.query["lang"]?
  tlang = env.params.query["tlang"]?

  if !label && !lang
    response = JSON.build do |json|
      json.object do
        json.field "captions" do
          json.array do
            captions.each do |caption|
              json.object do
                json.field "label", caption.name.simpleText
                json.field "languageCode", caption.languageCode
                json.field "url", "/api/v1/captions/#{id}?label=#{URI.escape(caption.name.simpleText)}"
              end
            end
          end
        end
      end
    end

    if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
      next JSON.parse(response).to_pretty_json
    else
      next response
    end
  end

  env.response.content_type = "text/vtt"

  caption = captions.select { |caption| caption.name.simpleText == label }

  if lang
    caption = captions.select { |caption| caption.languageCode == lang }
  end

  if caption.empty?
    halt env, status_code: 404
  else
    caption = caption[0]
  end

  caption_xml = client.get(caption.baseUrl + "&tlang=#{tlang}").body
  caption_xml = XML.parse(caption_xml)

  webvtt = <<-END_VTT
  WEBVTT
  Kind: captions
  Language: #{tlang || caption.languageCode}


  END_VTT

  caption_nodes = caption_xml.xpath_nodes("//transcript/text")
  caption_nodes.each_with_index do |node, i|
    start_time = node["start"].to_f.seconds
    duration = node["dur"]?.try &.to_f.seconds
    duration ||= start_time

    if caption_nodes.size > i + 1
      end_time = caption_nodes[i + 1]["start"].to_f.seconds
    else
      end_time = start_time + duration
    end

    start_time = "#{start_time.hours.to_s.rjust(2, '0')}:#{start_time.minutes.to_s.rjust(2, '0')}:#{start_time.seconds.to_s.rjust(2, '0')}.#{start_time.milliseconds.to_s.rjust(3, '0')}"
    end_time = "#{end_time.hours.to_s.rjust(2, '0')}:#{end_time.minutes.to_s.rjust(2, '0')}:#{end_time.seconds.to_s.rjust(2, '0')}.#{end_time.milliseconds.to_s.rjust(3, '0')}"

    text = HTML.unescape(node.content)
    text = text.gsub(/<font color="#[a-fA-F0-9]{6}">/, "")
    text = text.gsub(/<\/font>/, "")
    if md = text.match(/(?<name>.*) : (?<text>.*)/)
      text = "<v #{md["name"]}>#{md["text"]}</v>"
    end

    webvtt = webvtt + <<-END_CUE
    #{start_time} --> #{end_time}
    #{text}


    END_CUE
  end

  webvtt
end

get "/api/v1/comments/:id" do |env|
  locale = LOCALES[env.get("locale").as(String)]?
  region = env.params.query["region"]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]

  source = env.params.query["source"]?
  source ||= "youtube"

  format = env.params.query["format"]?
  format ||= "json"

  continuation = env.params.query["continuation"]?

  if source == "youtube"
    begin
      comments = fetch_youtube_comments(id, continuation, proxies, format, locale, region)
    rescue ex
      error_message = {"error" => ex.message}.to_json
      halt env, status_code: 500, response: error_message
    end

    next comments
  elsif source == "reddit"
    begin
      comments, reddit_thread = fetch_reddit_comments(id)
      content_html = template_reddit_comments(comments, locale)

      content_html = fill_links(content_html, "https", "www.reddit.com")
      content_html = replace_links(content_html)
    rescue ex
      comments = nil
      reddit_thread = nil
      content_html = ""
    end

    if !reddit_thread || !comments
      halt env, status_code: 404
    end

    if format == "json"
      reddit_thread = JSON.parse(reddit_thread.to_json).as_h
      reddit_thread["comments"] = JSON.parse(comments.to_json)

      if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
        next reddit_thread.to_pretty_json
      else
        next reddit_thread.to_json
      end
    else
      response = {
        "title"       => reddit_thread.title,
        "permalink"   => reddit_thread.permalink,
        "contentHtml" => content_html,
      }

      if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
        next response.to_pretty_json
      else
        next response.to_json
      end
    end
  end
end

get "/api/v1/insights/:id" do |env|
  locale = LOCALES[env.get("locale").as(String)]?

  id = env.params.url["id"]
  env.response.content_type = "application/json"

  error_message = {"error" => "YouTube has removed publicly-available analytics."}.to_json
  halt env, status_code: 410, response: error_message

  client = make_client(YT_URL)
  headers = HTTP::Headers.new
  html = client.get("/watch?v=#{id}&gl=US&hl=en&disable_polymer=1")

  headers["cookie"] = html.cookies.add_request_headers(headers)["cookie"]
  headers["content-type"] = "application/x-www-form-urlencoded"

  headers["x-client-data"] = "CIi2yQEIpbbJAQipncoBCNedygEIqKPKAQ=="
  headers["x-spf-previous"] = "https://www.youtube.com/watch?v=#{id}"
  headers["x-spf-referer"] = "https://www.youtube.com/watch?v=#{id}"

  headers["x-youtube-client-name"] = "1"
  headers["x-youtube-client-version"] = "2.20180719"

  body = html.body
  session_token = body.match(/'XSRF_TOKEN': "(?<session_token>[A-Za-z0-9\_\-\=]+)"/).not_nil!["session_token"]

  post_req = {
    "session_token" => session_token,
  }
  post_req = HTTP::Params.encode(post_req)

  response = client.post("/insight_ajax?action_get_statistics_and_data=1&v=#{id}", headers, post_req).body
  response = XML.parse(response)

  html_content = XML.parse_html(response.xpath_node(%q(//html_content)).not_nil!.content)
  graph_data = response.xpath_node(%q(//graph_data))
  if !graph_data
    error = html_content.xpath_node(%q(//p)).not_nil!.content
    next {"error" => error}.to_json
  end

  graph_data = JSON.parse(graph_data.content)

  view_count = 0_i64
  time_watched = 0_i64
  subscriptions_driven = 0
  shares = 0

  stats_nodes = html_content.xpath_nodes(%q(//table/tr/td))
  stats_nodes.each do |node|
    key = node.xpath_node(%q(.//span))
    value = node.xpath_node(%q(.//div))

    if !key || !value
      next
    end

    key = key.content
    value = value.content

    case key
    when "Views"
      view_count = value.delete(", ").to_i64
    when "Time watched"
      time_watched = value
    when "Subscriptions driven"
      subscriptions_driven = value.delete(", ").to_i
    when "Shares"
      shares = value.delete(", ").to_i
    end
  end

  avg_view_duration_seconds = html_content.xpath_node(%q(//div[@id="stats-chart-tab-watch-time"]/span/span[2])).not_nil!.content
  avg_view_duration_seconds = decode_length_seconds(avg_view_duration_seconds)

  response = {
    "viewCount"              => view_count,
    "timeWatchedText"        => time_watched,
    "subscriptionsDriven"    => subscriptions_driven,
    "shares"                 => shares,
    "avgViewDurationSeconds" => avg_view_duration_seconds,
    "graphData"              => graph_data,
  }

  if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
    next response.to_pretty_json
  else
    next response.to_json
  end
end

get "/api/v1/videos/:id" do |env|
  locale = LOCALES[env.get("locale").as(String)]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]
  region = env.params.query["region"]?

  begin
    video = fetch_video(id, proxies, region: region)
  rescue ex : VideoRedirect
    next env.redirect "/api/v1/videos/#{ex.message}"
  rescue ex
    error_message = {"error" => ex.message}.to_json
    halt env, status_code: 500, response: error_message
  end

  fmt_stream = video.fmt_stream(decrypt_function)
  adaptive_fmts = video.adaptive_fmts(decrypt_function)

  captions = video.captions

  video_info = JSON.build do |json|
    json.object do
      json.field "title", video.title
      json.field "videoId", video.id
      json.field "videoThumbnails" do
        generate_thumbnails(json, video.id)
      end

      video.description, description = html_to_content(video.description)

      json.field "description", description
      json.field "descriptionHtml", video.description
      json.field "published", video.published.to_unix
      json.field "publishedText", translate(locale, "`x` ago", recode_date(video.published, locale))
      json.field "keywords", video.keywords

      json.field "viewCount", video.views
      json.field "likeCount", video.likes
      json.field "dislikeCount", video.dislikes

      json.field "paid", video.paid
      json.field "premium", video.premium
      json.field "isFamilyFriendly", video.is_family_friendly
      json.field "allowedRegions", video.allowed_regions
      json.field "genre", video.genre
      json.field "genreUrl", video.genre_url

      json.field "author", video.author
      json.field "authorId", video.ucid
      json.field "authorUrl", "/channel/#{video.ucid}"

      json.field "authorThumbnails" do
        json.array do
          qualities = [32, 48, 76, 100, 176, 512]

          qualities.each do |quality|
            json.object do
              json.field "url", video.author_thumbnail.gsub("=s48-", "=s#{quality}-")
              json.field "width", quality
              json.field "height", quality
            end
          end
        end
      end

      json.field "subCountText", video.sub_count_text

      json.field "lengthSeconds", video.info["length_seconds"].to_i
      if video.info["allow_ratings"]?
        json.field "allowRatings", video.info["allow_ratings"] == "1"
      else
        json.field "allowRatings", false
      end
      json.field "rating", video.info["avg_rating"].to_f32

      if video.info["is_listed"]?
        json.field "isListed", video.info["is_listed"] == "1"
      end

      if video.player_response["streamingData"]?.try &.["hlsManifestUrl"]?
        host_url = make_host_url(Kemal.config.ssl || config.https_only, config.domain)

        host_params = env.request.query_params
        host_params.delete_all("v")

        hlsvp = video.player_response["streamingData"]["hlsManifestUrl"].as_s
        hlsvp = hlsvp.gsub("https://manifest.googlevideo.com", host_url)

        json.field "hlsUrl", hlsvp
      end

      json.field "adaptiveFormats" do
        json.array do
          adaptive_fmts.each do |fmt|
            json.object do
              json.field "index", fmt["index"]
              json.field "bitrate", fmt["bitrate"]
              json.field "init", fmt["init"]
              json.field "url", fmt["url"]
              json.field "itag", fmt["itag"]
              json.field "type", fmt["type"]
              json.field "clen", fmt["clen"]
              json.field "lmt", fmt["lmt"]
              json.field "projectionType", fmt["projection_type"]

              fmt_info = itag_to_metadata?(fmt["itag"])
              if fmt_info
                fps = fmt_info["fps"]?.try &.to_i || fmt["fps"]?.try &.to_i || 30
                json.field "fps", fps
                json.field "container", fmt_info["ext"]
                json.field "encoding", fmt_info["vcodec"]? || fmt_info["acodec"]

                if fmt_info["height"]?
                  json.field "resolution", "#{fmt_info["height"]}p"

                  quality_label = "#{fmt_info["height"]}p"
                  if fps > 30
                    quality_label += "60"
                  end
                  json.field "qualityLabel", quality_label

                  if fmt_info["width"]?
                    json.field "size", "#{fmt_info["width"]}x#{fmt_info["height"]}"
                  end
                end
              end
            end
          end
        end
      end

      json.field "formatStreams" do
        json.array do
          fmt_stream.each do |fmt|
            json.object do
              json.field "url", fmt["url"]
              json.field "itag", fmt["itag"]
              json.field "type", fmt["type"]
              json.field "quality", fmt["quality"]

              fmt_info = itag_to_metadata?(fmt["itag"])
              if fmt_info
                fps = fmt_info["fps"]?.try &.to_i || fmt["fps"]?.try &.to_i || 30
                json.field "fps", fps
                json.field "container", fmt_info["ext"]
                json.field "encoding", fmt_info["vcodec"]? || fmt_info["acodec"]

                if fmt_info["height"]?
                  json.field "resolution", "#{fmt_info["height"]}p"

                  quality_label = "#{fmt_info["height"]}p"
                  if fps > 30
                    quality_label += "60"
                  end
                  json.field "qualityLabel", quality_label

                  if fmt_info["width"]?
                    json.field "size", "#{fmt_info["width"]}x#{fmt_info["height"]}"
                  end
                end
              end
            end
          end
        end
      end

      json.field "captions" do
        json.array do
          captions.each do |caption|
            json.object do
              json.field "label", caption.name.simpleText
              json.field "languageCode", caption.languageCode
              json.field "url", "/api/v1/captions/#{id}?label=#{URI.escape(caption.name.simpleText)}"
            end
          end
        end
      end

      json.field "recommendedVideos" do
        json.array do
          video.info["rvs"]?.try &.split(",").each do |rv|
            rv = HTTP::Params.parse(rv)

            if rv["id"]?
              json.object do
                json.field "videoId", rv["id"]
                json.field "title", rv["title"]
                json.field "videoThumbnails" do
                  generate_thumbnails(json, rv["id"])
                end
                json.field "author", rv["author"]
                json.field "lengthSeconds", rv["length_seconds"].to_i
                json.field "viewCountText", rv["short_view_count_text"]
              end
            end
          end
        end
      end
    end
  end

  if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
    JSON.parse(video_info).to_pretty_json
  else
    video_info
  end
end

get "/api/v1/trending" do |env|
  locale = LOCALES[env.get("locale").as(String)]?

  env.response.content_type = "application/json"

  region = env.params.query["region"]?
  trending_type = env.params.query["type"]?

  begin
    trending = fetch_trending(trending_type, proxies, region, locale)
  rescue ex
    error_message = {"error" => ex.message}.to_json
    halt env, status_code: 500, response: error_message
  end

  videos = JSON.build do |json|
    json.array do
      trending.each do |video|
        json.object do
          json.field "title", video.title
          json.field "videoId", video.id
          json.field "videoThumbnails" do
            generate_thumbnails(json, video.id)
          end

          json.field "lengthSeconds", video.length_seconds
          json.field "viewCount", video.views

          json.field "author", video.author
          json.field "authorId", video.ucid
          json.field "authorUrl", "/channel/#{video.ucid}"

          json.field "published", video.published.to_unix
          json.field "publishedText", translate(locale, "`x` ago", recode_date(video.published, locale))
          json.field "description", video.description
          json.field "descriptionHtml", video.description_html
          json.field "liveNow", video.live_now
          json.field "paid", video.paid
          json.field "premium", video.premium
        end
      end
    end
  end

  if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
    JSON.parse(videos).to_pretty_json
  else
    videos
  end
end

get "/api/v1/channels/:ucid" do |env|
  locale = LOCALES[env.get("locale").as(String)]?

  env.response.content_type = "application/json"

  ucid = env.params.url["ucid"]
  sort_by = env.params.query["sort_by"]?.try &.downcase
  sort_by ||= "newest"

  begin
    author, ucid, auto_generated = get_about_info(ucid, locale)
  rescue ex
    error_message = {"error" => ex.message}.to_json
    halt env, status_code: 500, response: error_message
  end

  page = 1
  if auto_generated
    videos = [] of SearchVideo
    count = 0
  else
    begin
      videos, count = get_60_videos(ucid, page, auto_generated, sort_by)
    rescue ex
      error_message = {"error" => ex.message}.to_json
      halt env, status_code: 500, response: error_message
    end
  end

  client = make_client(YT_URL)
  channel_html = client.get("/channel/#{ucid}/about?disable_polymer=1").body
  channel_html = XML.parse_html(channel_html)
  banner = channel_html.xpath_node(%q(//div[@id="gh-banner"]/style)).not_nil!.content
  banner = "https:" + banner.match(/background-image: url\((?<url>[^)]+)\)/).not_nil!["url"]

  author = channel_html.xpath_node(%q(//a[contains(@class, "branded-page-header-title-link")])).not_nil!.content
  author_url = channel_html.xpath_node(%q(//a[@class="channel-header-profile-image-container spf-link"])).not_nil!["href"]
  author_thumbnail = channel_html.xpath_node(%q(//img[@class="channel-header-profile-image"])).not_nil!["src"]
  description_html = channel_html.xpath_node(%q(//div[contains(@class,"about-description")]))
  description_html, description = html_to_content(description_html)

  paid = channel_html.xpath_node(%q(//meta[@itemprop="paid"])).not_nil!["content"] == "True"
  is_family_friendly = channel_html.xpath_node(%q(//meta[@itemprop="isFamilyFriendly"])).not_nil!["content"] == "True"
  allowed_regions = channel_html.xpath_node(%q(//meta[@itemprop="regionsAllowed"])).not_nil!["content"].split(",")

  related_channels = channel_html.xpath_nodes(%q(//div[contains(@class, "branded-page-related-channels")]/ul/li))
  related_channels = related_channels.map do |node|
    related_id = node["data-external-id"]?
    related_id ||= ""

    anchor = node.xpath_node(%q(.//h3[contains(@class, "yt-lockup-title")]/a))
    related_title = anchor.try &.["title"]
    related_title ||= ""

    related_author_url = anchor.try &.["href"]
    related_author_url ||= ""

    related_author_thumbnail = node.xpath_node(%q(.//img)).try &.["data-thumb"]
    related_author_thumbnail ||= ""

    {
      id:               related_id,
      author:           related_title,
      author_url:       related_author_url,
      author_thumbnail: related_author_thumbnail,
    }
  end

  total_views = 0_i64
  sub_count = 0_i64
  joined = Time.unix(0)
  metadata = channel_html.xpath_nodes(%q(//span[@class="about-stat"]))
  metadata.each do |item|
    case item.content
    when .includes? "views"
      total_views = item.content.delete("views •,").to_i64
    when .includes? "subscribers"
      sub_count = item.content.delete("subscribers").delete(",").to_i64
    when .includes? "Joined"
      joined = Time.parse(item.content.lchop("Joined "), "%b %-d, %Y", Time::Location.local)
    end
  end

  channel_info = JSON.build do |json|
    json.object do
      json.field "author", author
      json.field "authorId", ucid
      json.field "authorUrl", author_url

      json.field "authorBanners" do
        json.array do
          qualities = [{width: 2560, height: 424},
                       {width: 2120, height: 351},
                       {width: 1060, height: 175}]
          qualities.each do |quality|
            json.object do
              json.field "url", banner.gsub("=w1060", "=w#{quality[:width]}")
              json.field "width", quality[:width]
              json.field "height", quality[:height]
            end
          end

          json.object do
            json.field "url", banner.rchop("=w1060-fcrop64=1,00005a57ffffa5a8-nd-c0xffffffff-rj-k-no")
            json.field "width", 512
            json.field "height", 288
          end
        end
      end

      json.field "authorThumbnails" do
        json.array do
          qualities = [32, 48, 76, 100, 176, 512]

          qualities.each do |quality|
            json.object do
              json.field "url", author_thumbnail.gsub("/s100-", "/s#{quality}-")
              json.field "width", quality
              json.field "height", quality
            end
          end
        end
      end

      json.field "subCount", sub_count
      json.field "totalViews", total_views
      json.field "joined", joined.to_unix
      json.field "paid", paid

      json.field "autoGenerated", auto_generated
      json.field "isFamilyFriendly", is_family_friendly
      json.field "description", description
      json.field "descriptionHtml", description_html

      json.field "allowedRegions", allowed_regions

      json.field "latestVideos" do
        json.array do
          videos.each do |video|
            json.object do
              json.field "title", video.title
              json.field "videoId", video.id

              if auto_generated
                json.field "author", video.author
                json.field "authorId", video.ucid
                json.field "authorUrl", "/channel/#{video.ucid}"
              else
                json.field "author", author
                json.field "authorId", ucid
                json.field "authorUrl", "/channel/#{ucid}"
              end

              json.field "videoThumbnails" do
                generate_thumbnails(json, video.id)
              end

              json.field "description", video.description
              json.field "descriptionHtml", video.description_html

              json.field "viewCount", video.views
              json.field "published", video.published.to_unix
              json.field "publishedText", translate(locale, "`x` ago", recode_date(video.published, locale))
              json.field "lengthSeconds", video.length_seconds
              json.field "liveNow", video.live_now
              json.field "paid", video.paid
              json.field "premium", video.premium
            end
          end
        end
      end

      json.field "relatedChannels" do
        json.array do
          related_channels.each do |related_channel|
            json.object do
              json.field "author", related_channel[:author]
              json.field "authorId", related_channel[:id]
              json.field "authorUrl", related_channel[:author_url]

              json.field "authorThumbnails" do
                json.array do
                  qualities = [32, 48, 76, 100, 176, 512]

                  qualities.each do |quality|
                    json.object do
                      json.field "url", related_channel[:author_thumbnail].gsub("=s48-", "=s#{quality}-")
                      json.field "width", quality
                      json.field "height", quality
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
    JSON.parse(channel_info).to_pretty_json
  else
    channel_info
  end
end

["/api/v1/channels/:ucid/videos", "/api/v1/channels/videos/:ucid"].each do |route|
  get route do |env|
    locale = LOCALES[env.get("locale").as(String)]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]
    page = env.params.query["page"]?.try &.to_i?
    page ||= 1
    sort_by = env.params.query["sort"]?.try &.downcase
    sort_by ||= env.params.query["sort_by"]?.try &.downcase
    sort_by ||= "newest"

    begin
      author, ucid, auto_generated = get_about_info(ucid, locale)
    rescue ex
      error_message = {"error" => ex.message}.to_json
      halt env, status_code: 500, response: error_message
    end

    begin
      videos, count = get_60_videos(ucid, page, auto_generated, sort_by)
    rescue ex
      error_message = {"error" => ex.message}.to_json
      halt env, status_code: 500, response: error_message
    end

    result = JSON.build do |json|
      json.array do
        videos.each do |video|
          json.object do
            json.field "title", video.title
            json.field "videoId", video.id

            if auto_generated
              json.field "author", video.author
              json.field "authorId", video.ucid
              json.field "authorUrl", "/channel/#{video.ucid}"
            else
              json.field "author", author
              json.field "authorId", ucid
              json.field "authorUrl", "/channel/#{ucid}"
            end

            json.field "videoThumbnails" do
              generate_thumbnails(json, video.id)
            end

            json.field "description", video.description
            json.field "descriptionHtml", video.description_html

            json.field "viewCount", video.views
            json.field "published", video.published.to_unix
            json.field "publishedText", translate(locale, "`x` ago", recode_date(video.published, locale))
            json.field "lengthSeconds", video.length_seconds
            json.field "liveNow", video.live_now
            json.field "paid", video.paid
            json.field "premium", video.premium
          end
        end
      end
    end

    if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
      JSON.parse(result).to_pretty_json
    else
      result
    end
  end
end

["/api/v1/channels/:ucid/latest", "/api/v1/channels/latest/:ucid"].each do |route|
  get route do |env|
    locale = LOCALES[env.get("locale").as(String)]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]

    begin
      videos = get_latest_videos(ucid)
    rescue ex
      error_message = {"error" => ex.message}.to_json
      halt env, status_code: 500, response: error_message
    end

    response = JSON.build do |json|
      json.array do
        videos.each do |video|
          json.object do
            json.field "title", video.title
            json.field "videoId", video.id

            json.field "authorId", ucid
            json.field "authorUrl", "/channel/#{ucid}"

            json.field "videoThumbnails" do
              generate_thumbnails(json, video.id)
            end

            json.field "description", video.description
            json.field "descriptionHtml", video.description_html

            json.field "viewCount", video.views
            json.field "published", video.published.to_unix
            json.field "publishedText", translate(locale, "`x` ago", recode_date(video.published, locale))
            json.field "lengthSeconds", video.length_seconds
            json.field "liveNow", video.live_now
            json.field "paid", video.paid
            json.field "premium", video.premium
          end
        end
      end
    end

    if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
      JSON.parse(response).to_pretty_json
    else
      response
    end
  end
end

["/api/v1/channels/:ucid/playlists", "/api/v1/channels/playlists/:ucid"].each do |route|
  get route do |env|
    locale = LOCALES[env.get("locale").as(String)]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]
    continuation = env.params.query["continuation"]?
    sort_by = env.params.query["sort"]?.try &.downcase
    sort_by ||= env.params.query["sort_by"]?.try &.downcase
    sort_by ||= "last"

    begin
      author, ucid, auto_generated = get_about_info(ucid, locale)
    rescue ex
      error_message = ex.message
      halt env, status_code: 500, response: error_message
    end

    items, continuation = fetch_channel_playlists(ucid, author, auto_generated, continuation, sort_by)

    response = JSON.build do |json|
      json.object do
        json.field "playlists" do
          json.array do
            items.each do |item|
              json.object do
                if item.is_a?(SearchPlaylist)
                  json.field "title", item.title
                  json.field "playlistId", item.id

                  json.field "author", item.author
                  json.field "authorId", item.ucid
                  json.field "authorUrl", "/channel/#{item.ucid}"

                  json.field "videoCount", item.video_count
                  json.field "videos" do
                    json.array do
                      item.videos.each do |video|
                        json.object do
                          json.field "title", video.title
                          json.field "videoId", video.id
                          json.field "lengthSeconds", video.length_seconds

                          json.field "videoThumbnails" do
                            generate_thumbnails(json, video.id)
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end

        json.field "continuation", continuation
      end
    end

    if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
      JSON.parse(response).to_pretty_json
    else
      response
    end
  end
end

get "/api/v1/channels/search/:ucid" do |env|
  locale = LOCALES[env.get("locale").as(String)]?

  env.response.content_type = "application/json"

  ucid = env.params.url["ucid"]

  query = env.params.query["q"]?
  query ||= ""

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  count, search_results = channel_search(query, page, ucid)
  response = JSON.build do |json|
    json.array do
      search_results.each do |item|
        json.object do
          case item
          when SearchVideo
            json.field "type", "video"
            json.field "title", item.title
            json.field "videoId", item.id

            json.field "author", item.author
            json.field "authorId", item.ucid
            json.field "authorUrl", "/channel/#{item.ucid}"

            json.field "videoThumbnails" do
              generate_thumbnails(json, item.id)
            end

            json.field "description", item.description
            json.field "descriptionHtml", item.description_html

            json.field "viewCount", item.views
            json.field "published", item.published.to_unix
            json.field "publishedText", translate(locale, "`x` ago", recode_date(item.published, locale))
            json.field "lengthSeconds", item.length_seconds
            json.field "liveNow", item.live_now
            json.field "paid", item.paid
            json.field "premium", item.premium
          when SearchPlaylist
            json.field "type", "playlist"
            json.field "title", item.title
            json.field "playlistId", item.id

            json.field "author", item.author
            json.field "authorId", item.ucid
            json.field "authorUrl", "/channel/#{item.ucid}"

            json.field "videoCount", item.video_count
            json.field "videos" do
              json.array do
                item.videos.each do |video|
                  json.object do
                    json.field "title", video.title
                    json.field "videoId", video.id
                    json.field "lengthSeconds", video.length_seconds

                    json.field "videoThumbnails" do
                      generate_thumbnails(json, video.id)
                    end
                  end
                end
              end
            end
          when SearchChannel
            json.field "type", "channel"
            json.field "author", item.author
            json.field "authorId", item.ucid
            json.field "authorUrl", "/channel/#{item.ucid}"

            json.field "authorThumbnails" do
              json.array do
                qualities = [32, 48, 76, 100, 176, 512]

                qualities.each do |quality|
                  json.object do
                    json.field "url", item.author_thumbnail.gsub("=s176-", "=s#{quality}-")
                    json.field "width", quality
                    json.field "height", quality
                  end
                end
              end
            end

            json.field "subCount", item.subscriber_count
            json.field "videoCount", item.video_count
            json.field "description", item.description
            json.field "descriptionHtml", item.description_html
          end
        end
      end
    end
  end

  if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
    JSON.parse(response).to_pretty_json
  else
    response
  end
end

get "/api/v1/search" do |env|
  locale = LOCALES[env.get("locale").as(String)]?
  region = env.params.query["region"]?

  env.response.content_type = "application/json"

  query = env.params.query["q"]?
  query ||= ""

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  sort_by = env.params.query["sort_by"]?.try &.downcase
  sort_by ||= "relevance"

  date = env.params.query["date"]?.try &.downcase
  date ||= ""

  duration = env.params.query["duration"]?.try &.downcase
  duration ||= ""

  features = env.params.query["features"]?.try &.split(",").map { |feature| feature.downcase }
  features ||= [] of String

  content_type = env.params.query["type"]?.try &.downcase
  content_type ||= "video"

  begin
    search_params = produce_search_params(sort_by, date, content_type, duration, features)
  rescue ex
    env.response.status_code = 400
    next JSON.build do |json|
      json.object do
        json.field "error", ex.message
      end
    end
  end

  count, search_results = search(query, page, search_params, proxies, region).as(Tuple)
  response = JSON.build do |json|
    json.array do
      search_results.each do |item|
        json.object do
          case item
          when SearchVideo
            json.field "type", "video"
            json.field "title", item.title
            json.field "videoId", item.id

            json.field "author", item.author
            json.field "authorId", item.ucid
            json.field "authorUrl", "/channel/#{item.ucid}"

            json.field "videoThumbnails" do
              generate_thumbnails(json, item.id)
            end

            json.field "description", item.description
            json.field "descriptionHtml", item.description_html

            json.field "viewCount", item.views
            json.field "published", item.published.to_unix
            json.field "publishedText", translate(locale, "`x` ago", recode_date(item.published, locale))
            json.field "lengthSeconds", item.length_seconds
            json.field "liveNow", item.live_now
            json.field "paid", item.paid
            json.field "premium", item.premium
          when SearchPlaylist
            json.field "type", "playlist"
            json.field "title", item.title
            json.field "playlistId", item.id

            json.field "author", item.author
            json.field "authorId", item.ucid
            json.field "authorUrl", "/channel/#{item.ucid}"

            json.field "videoCount", item.video_count
            json.field "videos" do
              json.array do
                item.videos.each do |video|
                  json.object do
                    json.field "title", video.title
                    json.field "videoId", video.id
                    json.field "lengthSeconds", video.length_seconds

                    json.field "videoThumbnails" do
                      generate_thumbnails(json, video.id)
                    end
                  end
                end
              end
            end
          when SearchChannel
            json.field "type", "channel"
            json.field "author", item.author
            json.field "authorId", item.ucid
            json.field "authorUrl", "/channel/#{item.ucid}"

            json.field "authorThumbnails" do
              json.array do
                qualities = [32, 48, 76, 100, 176, 512]

                qualities.each do |quality|
                  json.object do
                    json.field "url", item.author_thumbnail.gsub("=s176-", "=s#{quality}-")
                    json.field "width", quality
                    json.field "height", quality
                  end
                end
              end
            end

            json.field "subCount", item.subscriber_count
            json.field "videoCount", item.video_count
            json.field "description", item.description
            json.field "descriptionHtml", item.description_html
          end
        end
      end
    end
  end

  if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
    JSON.parse(response).to_pretty_json
  else
    response
  end
end

get "/api/v1/playlists/:plid" do |env|
  locale = LOCALES[env.get("locale").as(String)]?

  env.response.content_type = "application/json"
  plid = env.params.url["plid"]

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  format = env.params.query["format"]?
  format ||= "json"

  continuation = env.params.query["continuation"]?

  if plid.starts_with? "RD"
    next env.redirect "/api/v1/mixes/#{plid}"
  end

  begin
    playlist = fetch_playlist(plid, locale)
  rescue ex
    error_message = {"error" => "Playlist is empty"}.to_json
    halt env, status_code: 500, response: error_message
  end

  begin
    videos = fetch_playlist_videos(plid, page, playlist.video_count, continuation, locale)
  rescue ex
    videos = [] of PlaylistVideo
  end

  response = JSON.build do |json|
    json.object do
      json.field "title", playlist.title
      json.field "playlistId", playlist.id

      json.field "author", playlist.author
      json.field "authorId", playlist.ucid
      json.field "authorUrl", "/channel/#{playlist.ucid}"

      json.field "authorThumbnails" do
        json.array do
          qualities = [32, 48, 76, 100, 176, 512]

          qualities.each do |quality|
            json.object do
              json.field "url", playlist.author_thumbnail.gsub("=s100-", "=s#{quality}-")
              json.field "width", quality
              json.field "height", quality
            end
          end
        end
      end

      json.field "description", playlist.description
      json.field "descriptionHtml", playlist.description_html
      json.field "videoCount", playlist.video_count

      json.field "viewCount", playlist.views
      json.field "updated", playlist.updated.to_unix

      json.field "videos" do
        json.array do
          videos.each do |video|
            json.object do
              json.field "title", video.title
              json.field "videoId", video.id

              json.field "author", video.author
              json.field "authorId", video.ucid
              json.field "authorUrl", "/channel/#{video.ucid}"

              json.field "videoThumbnails" do
                generate_thumbnails(json, video.id)
              end

              json.field "index", video.index
              json.field "lengthSeconds", video.length_seconds
            end
          end
        end
      end
    end
  end

  if format == "html"
    response = JSON.parse(response)
    playlist_html = template_playlist(response)
    next_video = response["videos"].as_a[1]?.try &.["videoId"]

    response = {
      "playlistHtml" => playlist_html,
      "nextVideo"    => next_video,
    }.to_json
  end

  if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
    JSON.parse(response).to_pretty_json
  else
    response
  end
end

get "/api/v1/mixes/:rdid" do |env|
  locale = LOCALES[env.get("locale").as(String)]?

  env.response.content_type = "application/json"

  rdid = env.params.url["rdid"]

  continuation = env.params.query["continuation"]?
  continuation ||= rdid.lchop("RD")[0, 11]

  format = env.params.query["format"]?
  format ||= "json"

  begin
    mix = fetch_mix(rdid, continuation, locale: locale)

    if !rdid.ends_with? continuation
      mix = fetch_mix(rdid, mix.videos[1].id)
      index = mix.videos.index(mix.videos.select { |video| video.id == continuation }[0]?)
    end
    index ||= 0

    mix.videos = mix.videos[index..-1]
  rescue ex
    error_message = {"error" => ex.message}.to_json
    halt env, status_code: 500, response: error_message
  end

  response = JSON.build do |json|
    json.object do
      json.field "title", mix.title
      json.field "mixId", mix.id

      json.field "videos" do
        json.array do
          mix.videos.each do |video|
            json.object do
              json.field "title", video.title
              json.field "videoId", video.id
              json.field "author", video.author

              json.field "authorId", video.ucid
              json.field "authorUrl", "/channel/#{video.ucid}"

              json.field "videoThumbnails" do
                json.array do
                  generate_thumbnails(json, video.id)
                end
              end

              json.field "index", video.index
              json.field "lengthSeconds", video.length_seconds
            end
          end
        end
      end
    end
  end

  if format == "html"
    response = JSON.parse(response)
    playlist_html = template_mix(response)
    next_video = response["videos"].as_a[1]?.try &.["videoId"]
    next_video ||= ""

    response = {
      "playlistHtml" => playlist_html,
      "nextVideo"    => next_video,
    }.to_json
  end

  if env.params.query["pretty"]? && env.params.query["pretty"] == "1"
    JSON.parse(response).to_pretty_json
  else
    response
  end
end

get "/api/manifest/dash/id/videoplayback" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.redirect "/videoplayback?#{env.params.query}"
end

get "/api/manifest/dash/id/videoplayback/*" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.redirect env.request.path.lchop("/api/manifest/dash/id")
end

get "/api/manifest/dash/id/:id" do |env|
  env.response.headers.add("Access-Control-Allow-Origin", "*")
  env.response.content_type = "application/dash+xml"

  local = env.params.query["local"]?.try &.== "true"
  id = env.params.url["id"]
  region = env.params.query["region"]?

  client = make_client(YT_URL)
  begin
    video = fetch_video(id, proxies, region: region)
  rescue ex : VideoRedirect
    url = "/api/manifest/dash/id/#{ex.message}"
    if local
      url += "?local=true"
    end

    next env.redirect url
  rescue ex
    halt env, status_code: 403
  end

  if dashmpd = video.player_response["streamingData"]["dashManifestUrl"]?.try &.as_s
    manifest = client.get(dashmpd).body

    manifest = manifest.gsub(/<BaseURL>[^<]+<\/BaseURL>/) do |baseurl|
      url = baseurl.lchop("<BaseURL>")
      url = url.rchop("</BaseURL>")

      if local
        url = URI.parse(url).full_path.lchop("/")
      end

      "<BaseURL>#{url}</BaseURL>"
    end

    next manifest
  end

  adaptive_fmts = video.adaptive_fmts(decrypt_function)

  if local
    adaptive_fmts.each do |fmt|
      fmt["url"] = URI.parse(fmt["url"]).full_path.lchop("/")
    end
  end

  audio_streams = video.audio_streams(adaptive_fmts).select { |stream| stream["type"].starts_with? "audio/mp4" }
  video_streams = video.video_streams(adaptive_fmts).select { |stream| stream["type"].starts_with? "video/mp4" }.uniq { |stream| stream["size"] }

  manifest = XML.build(indent: "  ", encoding: "UTF-8") do |xml|
    xml.element("MPD", "xmlns": "urn:mpeg:dash:schema:mpd:2011",
      "profiles": "urn:mpeg:dash:profile:isoff-live:2011", minBufferTime: "PT1.5S", type: "static",
      mediaPresentationDuration: "PT#{video.info["length_seconds"]}S") do
      xml.element("Period") do
        xml.element("AdaptationSet", mimeType: "audio/mp4", startWithSAP: 1, subsegmentAlignment: true) do
          audio_streams.each do |fmt|
            codecs = fmt["type"].split("codecs=")[1].strip('"')
            bandwidth = fmt["bitrate"]
            itag = fmt["itag"]
            url = fmt["url"]

            xml.element("Representation", id: fmt["itag"], codecs: codecs, bandwidth: bandwidth) do
              xml.element("AudioChannelConfiguration", schemeIdUri: "urn:mpeg:dash:23003:3:audio_channel_configuration:2011",
                value: "2")
              xml.element("BaseURL") { xml.text url }
              xml.element("SegmentBase", indexRange: fmt["index"]) do
                xml.element("Initialization", range: fmt["init"])
              end
            end
          end
        end

        xml.element("AdaptationSet", mimeType: "video/mp4", startWithSAP: 1, subsegmentAlignment: true,
          scanType: "progressive") do
          video_streams.each do |fmt|
            codecs = fmt["type"].split("codecs=")[1].strip('"')
            bandwidth = fmt["bitrate"]
            itag = fmt["itag"]
            url = fmt["url"]
            height, width = fmt["size"].split("x")

            xml.element("Representation", id: itag, codecs: codecs, width: width, height: height,
              startWithSAP: "1", maxPlayoutRate: "1",
              bandwidth: bandwidth, frameRate: fmt["fps"]) do
              xml.element("BaseURL") { xml.text url }
              xml.element("SegmentBase", indexRange: fmt["index"]) do
                xml.element("Initialization", range: fmt["init"])
              end
            end
          end
        end
      end
    end
  end

  manifest = manifest.gsub(%(<?xml version="1.0" encoding="UTF-8U"?>), %(<?xml version="1.0" encoding="UTF-8"?>))
  manifest = manifest.gsub(%(<?xml version="1.0" encoding="UTF-8V"?>), %(<?xml version="1.0" encoding="UTF-8"?>))
  manifest
end

get "/api/manifest/hls_variant/*" do |env|
  client = make_client(YT_URL)
  manifest = client.get(env.request.path)

  if manifest.status_code != 200
    halt env, status_code: manifest.status_code
  end

  env.response.content_type = "application/x-mpegURL"
  env.response.headers.add("Access-Control-Allow-Origin", "*")

  host_url = make_host_url(Kemal.config.ssl || config.https_only, config.domain)

  manifest = manifest.body
  manifest.gsub("https://www.youtube.com", host_url)
end

get "/api/manifest/hls_playlist/*" do |env|
  client = make_client(YT_URL)
  manifest = client.get(env.request.path)

  if manifest.status_code != 200
    halt env, status_code: manifest.status_code
  end

  host_url = make_host_url(Kemal.config.ssl || config.https_only, config.domain)

  manifest = manifest.body.gsub("https://www.youtube.com", host_url)
  manifest = manifest.gsub(/https:\/\/r\d---.{11}\.c\.youtube\.com/, host_url)
  fvip = manifest.match(/hls_chunk_host\/r(?<fvip>\d)---/).not_nil!["fvip"]
  manifest = manifest.gsub("seg.ts", "seg.ts/fvip/#{fvip}")

  env.response.content_type = "application/x-mpegURL"
  env.response.headers.add("Access-Control-Allow-Origin", "*")
  manifest
end

# YouTube /videoplayback links expire after 6 hours,
# so we have a mechanism here to redirect to the latest version
get "/latest_version" do |env|
  if env.params.query["download_widget"]?
    download_widget = JSON.parse(env.params.query["download_widget"])
    id = download_widget["id"].as_s
    itag = download_widget["itag"].as_s
    title = download_widget["title"].as_s
    local = "true"
  end

  id ||= env.params.query["id"]?
  itag ||= env.params.query["itag"]?

  region = env.params.query["region"]?

  local ||= env.params.query["local"]?
  local ||= "false"
  local = local == "true"

  if !id || !itag
    halt env, status_code: 400
  end

  video = fetch_video(id, proxies, region: region)

  fmt_stream = video.fmt_stream(decrypt_function)
  adaptive_fmts = video.adaptive_fmts(decrypt_function)

  urls = (fmt_stream + adaptive_fmts).select { |fmt| fmt["itag"] == itag }
  if urls.empty?
    halt env, status_code: 404
  elsif urls.size > 1
    halt env, status_code: 409
  end

  url = urls[0]["url"]
  if local
    url = URI.parse(url).full_path.not_nil!
  end

  if title
    url += "&title=#{title}"
  end

  env.redirect url
end

options "/videoplayback" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

options "/videoplayback/*" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

options "/api/manifest/dash/id/videoplayback" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

options "/api/manifest/dash/id/videoplayback/*" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

get "/videoplayback/*" do |env|
  path = env.request.path

  path = path.lchop("/videoplayback/")
  path = path.rchop("/")

  path = path.gsub(/mime\/\w+\/\w+/) do |mimetype|
    mimetype = mimetype.split("/")
    mimetype[0] + "/" + mimetype[1] + "%2F" + mimetype[2]
  end

  path = path.split("/")

  raw_params = {} of String => Array(String)
  path.each_slice(2) do |pair|
    key, value = pair
    value = URI.unescape(value)

    if raw_params[key]?
      raw_params[key] << value
    else
      raw_params[key] = [value]
    end
  end

  query_params = HTTP::Params.new(raw_params)

  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.redirect "/videoplayback?#{query_params}"
end

get "/videoplayback" do |env|
  query_params = env.params.query

  fvip = query_params["fvip"]? || "3"
  mn = query_params["mn"].split(",")[-1]
  host = "https://r#{fvip}---#{mn}.googlevideo.com"
  url = "/videoplayback?#{query_params.to_s}"

  headers = env.request.headers
  headers.delete("Host")
  headers.delete("Cookie")
  headers.delete("User-Agent")
  headers.delete("Referer")

  region = query_params["region"]?

  response = HTTP::Client::Response.new(403)
  loop do
    begin
      client = make_client(URI.parse(host), proxies, region)
      response = client.head(url, headers)
      break
    rescue ex
    end
  end

  if response.headers["Location"]?
    url = URI.parse(response.headers["Location"])
    env.response.headers["Access-Control-Allow-Origin"] = "*"

    url = url.full_path
    if region
      url += "&region=#{region}"
    end

    next env.redirect url
  end

  if response.status_code >= 400
    halt env, status_code: response.status_code
  end

  client = make_client(URI.parse(host), proxies, region)
  client.get(url, headers) do |response|
    env.response.status_code = response.status_code

    if title = env.params.query["title"]?
      # https://blog.fastmail.com/2011/06/24/download-non-english-filenames/
      env.response.headers["Content-Disposition"] = "attachment; filename=\"#{URI.escape(title)}\"; filename*=UTF-8''#{URI.escape(title)}"
    end

    response.headers.each do |key, value|
      env.response.headers[key] = value
    end

    env.response.headers["Access-Control-Allow-Origin"] = "*"

    begin
      chunk_size = 4096
      size = 1
      while size > 0
        size = IO.copy(response.body_io, env.response.output, chunk_size)
        env.response.flush
        Fiber.yield
      end
    rescue ex
      break
    end
  end
end

get "/ggpht*" do |env|
end

get "/ggpht/*" do |env|
  host = "https://yt3.ggpht.com"
  client = make_client(URI.parse(host))
  url = env.request.path.lchop("/ggpht")

  headers = env.request.headers
  headers.delete("Host")
  headers.delete("Cookie")
  headers.delete("User-Agent")
  headers.delete("Referer")

  client.get(url, headers) do |response|
    env.response.status_code = response.status_code
    response.headers.each do |key, value|
      env.response.headers[key] = value
    end

    if response.status_code == 304
      break
    end

    chunk_size = 4096
    size = 1
    if response.headers.includes_word?("Content-Encoding", "gzip")
      Gzip::Writer.open(env.response) do |deflate|
        until size == 0
          size = IO.copy(response.body_io, deflate)
          env.response.flush
        end
      end
    elsif response.headers.includes_word?("Content-Encoding", "deflate")
      Flate::Writer.open(env.response) do |deflate|
        until size == 0
          size = IO.copy(response.body_io, deflate)
          env.response.flush
        end
      end
    else
      until size == 0
        size = IO.copy(response.body_io, env.response, chunk_size)
        env.response.flush
      end
    end
  end
end

get "/vi/:id/:name" do |env|
  id = env.params.url["id"]
  name = env.params.url["name"]

  host = "https://i.ytimg.com"
  client = make_client(URI.parse(host))

  if name == "maxres.jpg"
    VIDEO_THUMBNAILS.each do |thumb|
      if client.head("/vi/#{id}/#{thumb[:url]}.jpg").status_code == 200
        name = thumb[:url] + ".jpg"
        break
      end
    end
  end
  url = "/vi/#{id}/#{name}"

  headers = env.request.headers
  headers.delete("Host")
  headers.delete("Cookie")
  headers.delete("User-Agent")
  headers.delete("Referer")

  client.get(url, headers) do |response|
    env.response.status_code = response.status_code
    response.headers.each do |key, value|
      env.response.headers[key] = value
    end

    if response.status_code == 304
      break
    end

    chunk_size = 4096
    size = 1
    if response.headers.includes_word?("Content-Encoding", "gzip")
      Gzip::Writer.open(env.response) do |deflate|
        until size == 0
          size = IO.copy(response.body_io, deflate)
          env.response.flush
        end
      end
    elsif response.headers.includes_word?("Content-Encoding", "deflate")
      Flate::Writer.open(env.response) do |deflate|
        until size == 0
          size = IO.copy(response.body_io, deflate)
          env.response.flush
        end
      end
    else
      until size == 0
        size = IO.copy(response.body_io, env.response, chunk_size)
        env.response.flush
      end
    end
  end
end

error 404 do |env|
  env.response.content_type = "application/json"

  error_message = "404 Not Found"
  {"error" => error_message}.to_json
end

error 500 do |env|
  env.response.content_type = "application/json"

  error_message = "500 Server Error"
  {"error" => error_message}.to_json
end

# Add redirect if SSL is enabled
if Kemal.config.ssl
  spawn do
    server = HTTP::Server.new do |context|
      redirect_url = "https://#{context.request.host}#{context.request.path}"
      if context.request.query
        redirect_url += "?#{context.request.query}"
      end
      context.response.headers.add("Location", redirect_url)
      context.response.status_code = 301
    end

    server.bind_tcp "0.0.0.0", 80
    server.listen
  end
end

Kemal.config.powered_by_header = false
add_handler APIHandler.new

Kemal.config.logger = logger
Kemal.run
