require 'json'
require 'logger'
require 'net/http'
require 'pp'
require 'uri'

require 'gtk2'
require 'ld-eventsource'

module JSONFetcher
  # Performs a HTTPS request against the given URL, expecting a JSON document
  # in the HTTP response's body. Returns the decoded JSON document (either a
  # Ruby Hash or Array).
  def self.get(url)
    puts("HTTPS GET #{url}")
    uri = URI(url)
    obj = nil # SCOPE

    http = Net::HTTP.start(uri.host, uri.port, :use_ssl => true) do |http|
      req = Net::HTTP::Get.new(uri)
      req["Accept"] = "application/json"
      res = http.request(req)
      obj = JSON.load(res.body)
    end

    return obj
  end
end

# XXX should probably leverage Gtk.init_add()
class Application
   def initialize
    @latest_event = {:NEW => false,}
    @schedule = {}
    @last_message_n = -1
    @most_recent_batter = nil
    @current_day = -1

    setup_team_map

    #####

    setup_main_hbox
    setup_main_vbox
    setup_game_changer
    setup_weather_indicator
    setup_inning_marker
    setup_bases_widget
    setup_count_widget
    setup_playerinfo
    setup_events_box

    setup_team_view

    setup_notebook
    setup_main_window

    #####

    setup_stream_thread
  end

  def setup_main_hbox
    @main_hbox = Gtk::HBox.new
  end

  private def setup_main_vbox
    @main_vbox = Gtk::VBox.new
    @main_hbox.pack_end(@main_vbox)
  end

  private def setup_game_changer
    @game_changer = Gtk::ComboBox.new(true)
    @game_changer.signal_connect("changed") { |_| self.on_game_select } 
    @main_vbox.pack_start(@game_changer)
  end

  def get_current_game_index
    return @game_changer.active
  end

  def current_game_descr
    return @game_changer.active_text
  end

  def on_game_select
    puts ">>> I'M NOW TUNED IN TO: #{self.current_game_descr}"
  end

  private def setup_weather_indicator
    @weather_indicator = Gtk::Label.new("(weather)")
    @main_vbox.pack_start(@weather_indicator)
  end

  # Mapping provided by SIBR:
  # https://github.com/Society-for-Internet-Blaseball-Research/blaseball-api-spec/blob/master/game-main.md
  def update_weather(weather)
    weather_map = {
      0 => "Void",
      1 => "Sun 2",
      2 => "Overcast",
      3 => "Rainy",
      4 => "Sandstorm",
      5 => "Snowy",
      6 => "Acidic",
      7 => "Solar Eclipse",
      8 => "Glitter",
      9 => "Blooddrain",
      10 => "Peanuts",
      11 => "Lots of Birds",
      12 => "Feedback",
      13 => "Reverb",
      14 => "Black Hole",
      17 => "Coffee 3s",
      18 => "Flooding",
    }
    weather_s = weather_map[weather] || "(weather)"
    @weather_indicator.text = "(#{weather}) #{weather_s}"
  end

  private def setup_inning_marker
    @inning_marker = Gtk::Label.new("")
    @main_vbox.pack_start(@inning_marker)
  end

  def update_inning_marker(n, is_top)
    fmt = "%s of %d"
    @inning_marker.text = is_top ? sprintf(fmt, "Top", n) : sprintf(fmt, "Bot", n)
  end

  private def setup_bases_widget
    @bases_widget = Gtk::Label.new("(bases)")
    @main_vbox.pack_start(@bases_widget)
  end

  def update_bases_widget(obj)
    bases_occupied = obj[:bases_occupied]
    baseunners = obj[:baserunners]
    baserunner_names = obj[:baserunner_names]

    # I'm not 110% certain this is how we determine which baserunners are at
    # which bases, but it seems to work every time.
    text = ""
    bases_occupied.each_with_index do |base, i|
      text += "#{base+1}B: #{baserunner_names[i]}\n"
    end

    @bases_widget.text = text
  end

  private def setup_count_widget
    @count_widget = Gtk::Label.new("(count)")
    @main_vbox.pack_start(@count_widget)
  end

  def update_count_widget(balls, strikes, outs)
    @count_widget.text = "#{balls}-#{strikes}. #{outs} down."
  end

  private def setup_playerinfo
    # XXX this should be an "unknown"/"default" picture
    @portrait = Gtk::Image.new("data/portraits/2b157c5c-9a6a-45a6-858f-bf4cf4cbc0bd.jpg")

    @playerinfo_name_label = Gtk::Label.new("(unknown player)")
    @playerinfo_avg_label = Gtk::Label.new("(batting avg)")

    @playerinfo_vbox = Gtk::VBox.new(false, 2)
    @playerinfo_vbox.pack_start(@portrait)
    @playerinfo_vbox.pack_start(@playerinfo_name_label)
    @playerinfo_vbox.pack_start(@playerinfo_avg_label)

    @main_hbox.pack_start(@playerinfo_vbox)
  end

  # XXX I should probably fetch the name based on the ID instead?
  def update_playerinfo(player_id, player_name)
    #player_id = "2b157c5c-9a6a-45a6-858f-bf4cf4cbc0bd"
    candidate = File.expand_path("data/portraits/#{player_id}.jpg")
    real_picture = File.file?(candidate) ? candidate : "data/unknown_portrait.png"
    @portrait.pixbuf = GdkPixbuf::Pixbuf.new(:file => real_picture)
    @playerinfo_name_label.text = "#{player_name} (#{player_id})"
  end

  private def setup_events_box
    @events_list = Gtk::ListStore.new(String, String)
    @events_list.append # Can't get an iterator unless there's something to iterate on
    @events_list_iter = @events_list.get_iter("0")
    @events_list_iter.first!

    # I.e.: "The data first column in the ListStore will be displayed in the
    # first column of the TreeView."
    @events_box = Gtk::TreeView.new(@events_list)
    @events_box.insert_column(Gtk::TreeViewColumn.new("Id", Gtk::CellRendererText.new, :text => 0), 0)
    @events_box.insert_column(Gtk::TreeViewColumn.new("Descr", Gtk::CellRendererText.new, :text => 1), 1)

    @events_scrollwindow = Gtk::ScrolledWindow.new
    @events_scrollwindow.add_with_viewport(@events_box)
    @main_vbox.pack_start(@events_scrollwindow)
  end

  # An "event" in this case is a single message from a single game.
  def new_event(n, text)
    @events_list_iter.set_value(0, n.to_s)
    @events_list_iter.set_value(1, text)
    @events_list.append
    @events_list_iter.next!

    if false # XXX actually this is supposed to be just an option
      # XXX stupid hack to force macOS's speech synthesis to actually respect periods
      spoken_text = text.gsub('.', '..')
      GLib::Spawn.async(Dir.pwd, ["say", "-v", "Daniel", "-r", "200", spoken_text], "", 0) # XXX Haven't found the actual docs for this yet
    end
  end

  private def setup_team_view
    @team_name_widget = Gtk::Label.new("")
    @team_slogan_widget = Gtk::Label.new("")
    @team_division_widget = Gtk::Label.new("")

    @team_view = Gtk::VBox.new
    @team_view.pack_start(@team_name_widget)
    @team_view.pack_start(@team_slogan_widget)
    @team_view.pack_start(@team_division_widget)
  end

  def display_team_info(id)
    t = @team_map[id]
    return if not t
    @team_name_widget.text = t["full_name"] || "(full name)"
    @team_slogan_widget.text = t["team_slogan"] || "(slogan)"
    @team_division_widget.text = t["division"] || "(division)"
    @team_view.show_all
  end

  private def setup_notebook
    @notebook = Gtk::Notebook.new
    @notebook.append_page(@main_hbox, Gtk::Label.new("MAIN"))
    @notebook.append_page(@team_view, Gtk::Label.new("TEAM_VIEWER"))

    @notebook.signal_connect("switch-page") do |notebook, page, page_num|
      if page_num == 1
        display_team_info("f02aeae2-5e6a-4098-9842-02d2273f25c7")
      end
    end
  end

  private def setup_main_window
    @window = Gtk::Window.new
    @window.title = "Blaseball"
    @window.set_default_size(1280, 720)

    @window.add(@notebook)

    @window.signal_connect("destroy") do
      Gtk.main_quit
    end

    Gtk.quit_add(0) do
      puts("Quitting")
      @sse_client.close
    end
    
    @window.show_all
  end

  # Obtains the list of all active/current teams from SIBR, and populates the
  # @team_map cache.
  private def setup_team_map
    @team_map = {}

    Gtk.init_add do
      Thread.new do
        teams = JSONFetcher.get("https://api.blaseball-reference.com/v2/teams?season=current")

        teams.each do |team|
          if team["current_team_status"] == "active"
            @team_map[team["team_id"]] = team
          end
        end

        @team_map.each do |id, team|
          $stderr.puts("GOT TEAM INFO FOR #{team['full_name']}")
        end
      end
    end
  end

  # XXX Isn't it a problem that I'm updating the avg_label widget inside of a
  # sub-thread?
  def get_hitting_stats(player_id)
    Thread.new do
      obj = JSONFetcher.get("https://api.blaseball-reference.com/v2/stats?type=season&season=current&group=hitting&playerId=#{player_id}")
      stat = obj[0]['splits'][0]['stat']
      avg = stat['batting_average']
      hr = stat['home_runs']
      @playerinfo_avg_label.text = "AVG: #{avg.to_s}\nHR: #{hr.to_s}"
    end
  end

  # It is the caller's responsibility to ensure this method isn't called more
  # than once per game-day.
  def process_latest_schedule
    @schedule[:games].each_with_index do |game, i|
      descr = sprintf("%s at %s", game["awayTeamName"], game["homeTeamName"])
      @game_changer.insert_text(i, descr)
    end
  end

  # Takes the "pre-massaged" message and updates the UI based on the new data.
  # Because we're updating the UI, this method *cannot* be executed in a
  # separate thread; it has to happen in Gtk's main thread.
  #
  # It is the caller's responsibility to make sure this called only once
  # each event.
  def process_latest_event
    e = @latest_event

    new_event(e[:play_count], e[:text])
    update_bases_widget({
      :bases_occupied => e[:bases_occupied],
      :baserunners => e[:baserunners],
      :baserunner_names => e[:baserunner_names],
    })
    update_inning_marker(e[:inning], e[:is_top]) 
    update_count_widget(e[:current_balls], e[:current_strikes], e[:current_outs])
    update_weather(e[:weather])

    # Who's at the plate now?  Remember, there is no "batter" as such
    # once they're running.
    #
    # Also, we don't fetch new hitting stats if it's already the player at-bat.
    batterid = e[:is_top] ? e[:away_batter] : e[:home_batter]
    battername = e[:is_top] ? e[:away_batter_name] : e[:home_batter_name]

    if batterid && battername && (batterid != @most_recent_batter)
      @most_recent_batter = batterid
      update_playerinfo(batterid, battername)
      get_hitting_stats(batterid)
    end
  end

  # The goal is to avoid doing any GTK-related stuff inside of the
  # SSE-client-thread. Turns out that's kinda problematic. 
  #
  # I'm still kinda convinced there's some shenanigans inside of the SSE client
  # itself.
  #
  # XXX Also I really don't like needing to sleep there. Doesn't seem right.
  # XXX Actually it *really sucks* because it makes e.g. resizing the window be
  # stupidly slow.
  private def setup_stream_thread
    Gtk.idle_add {
      if @schedule[:games] && (@current_day != @schedule[:day])
        process_latest_schedule 
        @current_day = @schedule[:day]
      end

      if @latest_event[:NEW]
        process_latest_event 
        @latest_event.clear
        @latest_event[:NEW] = false
      end

      sleep 0.1 # To avoid ridiculous CPU usage
      true # To guarantee this idle-function will always loop
    }

    puts "Setting up SSE client"
    logger = Logger.new($stdout)
    logger.level = Logger::WARN

    @sse_client = SSE::Client.new("https://www.blaseball.com/events/streamData", logger: logger, read_timeout: nil) do |client|
      client.on_event do |event|
        data = JSON.load(event.data)

        # The schedule contains data for the whole day, basically.
        schedule = data["value"]["games"]["schedule"]
        @schedule[:games] = schedule
        @schedule[:day] = data["value"]["games"]["sim"]["day"]

        # The 'item' is for the specific game we've tuned into.
        #
        # Sometimes we get the same message sent to us twice (especially when
        # there's a home run, for some reason). Don't try to update the
        # @latest_event in that case.
        item = schedule[self.get_current_game_index]
        playcount = item["playCount"]
        if playcount != @last_message_n
          @last_message_n = playcount
          puts ">> NEW MESSAGE (#{playcount}) <<"
          @latest_event[:NEW] = true
          @latest_event[:text] = item["lastUpdate"]
          @latest_event[:play_count] = playcount
          @latest_event[:bases_occupied] = item["basesOccupied"]
          @latest_event[:baserunners] = item["baseRunners"]
          @latest_event[:baserunner_names] = item["baseRunnerNames"]
          @latest_event[:inning] = item["inning"] + 1 # +1 because it's zero-based
          @latest_event[:is_top] = item["topOfInning"]
          @latest_event[:away_batter] = item["awayBatter"]
          @latest_event[:away_batter_name] = item["awayBatterName"]
          @latest_event[:home_batter] = item["homeBatter"]
          @latest_event[:home_batter_name] = item["homeBatterName"]
          @latest_event[:current_balls] = item["atBatBalls"]
          @latest_event[:current_strikes] = item["atBatStrikes"]
          @latest_event[:current_outs] = item["halfInningOuts"]
          @latest_event[:weather] = item["weather"]
        end
      end
    end
  end

  def main
    Gtk.main
  end
end

########## ########## ##########

if $0 == __FILE__
  app = Application.new
  app.main
end
