module Castanaut
  # The movie class is the containing context within which screenplays are 
  # invoked. It provides a number of basic stage directions for your 
  # screenplays, and can be extended with plugins.
  class Movie

    # Runs the "screenplay", which is a file containing Castanaut instructions.
    #
    def initialize(screenplay)
      perms_test

      if !screenplay || !File.exists?(screenplay)
				usage(0, 'Castanaut: Automate your screencasts.')
        # raise Castanaut::Exceptions::ScreenplayNotFound 
      end
      @screenplay_path = screenplay

      File.open(FILE_RUNNING, 'w') {|f| f.write('')}

      begin
        # We run the movie in a separate thread; in the main thread we 
        # continue to check the "running" file flag and kill the movie if 
        # it is removed.
        movie = Thread.new do
          begin
            eval(IO.read(@screenplay_path), binding)
          rescue => e
            @e = e
          ensure
            File.unlink(FILE_RUNNING) if File.exists?(FILE_RUNNING)
          end
        end

        while File.exists?(FILE_RUNNING)
          sleep 0.5
          break unless movie.alive?
        end

        if movie.alive?
          movie.kill
          raise Castanaut::Exceptions::AbortedByUser
        end

        raise @e if @e
      rescue => e
        puts "ABNORMAL EXIT: #{e.message}\n" + e.backtrace.join("\n")
      ensure
        roll_credits
        File.unlink(FILE_RUNNING) if File.exists?(FILE_RUNNING)
      end
    end

    # Launch the application matching the string given in the first argument.
    # (This resolution is handled by Applescript.)
    #
    # If the options hash is given, it should contain the co-ordinates for
    # the window (top, left, width, height). The to method will format these
    # co-ordinates appropriately.
    #
    def launch(app_name, *options)
      options = combine_options(*options)

      ensure_window = ""
      case app_name.downcase
        when "safari"
          ensure_window = "if (count(windows)) < 1 then make new document"
      end

      positioning = ""
      if options[:to]
        pos = "#{options[:to][:left]}, #{options[:to][:top]}"
        dims = "#{options[:to][:left] + options[:to][:width]}, " +
          "#{options[:to][:top] + options[:to][:height]}"
        if options[:to][:width]
          positioning = "set bounds of front window to {#{pos}, #{dims}}"
        else
          positioning = "set position of front window to {#{pos}}"
        end
      end

      execute_applescript(%Q`
        tell application "#{app_name}"
          activate
          #{ensure_window}
          #{positioning}
        end tell
      `)
    end

    # Move the mouse cursor to the specified co-ordinates.
    #
    def cursor(*options)
      options = combine_options(*options)
      apply_offset(options)
      @cursor_loc ||= {}
      @cursor_loc[:x] = options[:to][:left]
      @cursor_loc[:y] = options[:to][:top]
      automatically "mousemove #{@cursor_loc[:x]} #{@cursor_loc[:y]}"
    end

    alias :move :cursor

    # Send a mouse-click at the current mouse location.
    #
    def click(btn = 'left')
      automatically "mouseclick #{mouse_button_translate(btn)}"
    end

    # Send a double-click at the current mouse location.
    #
    def doubleclick(btn = 'left')
      automatically "mousedoubleclick #{mouse_button_translate(btn)}"
    end
    
    # Send a triple-click at the current mouse location.
    # 
    def tripleclick(btn = 'left')
      automatically "mousetripleclick #{mouse_button_translate(btn)}"
    end

    # Press the button down at the current mouse location. Does not 
    # release the button until the mouseup method is invoked.
    #
    def mousedown(btn = 'left')
      automatically "mousedown #{mouse_button_translate(btn)}"
    end

    # Releases the mouse button pressed by a previous mousedown.
    #
    def mouseup(btn = 'left')
      automatically "mouseup #{mouse_button_translate(btn)}"
    end

    # "Drags" the mouse by (effectively) issuing a mousedown at the current 
    # mouse location, then moving the mouse to the specified coordinates, then
    # issuing a mouseup.
    #
    def drag(*options)
      options = combine_options(*options)
      apply_offset(options)
      automatically "mousedrag #{options[:to][:left]} #{options[:to][:top]}"
    end

    # Sends the characters into the active control in the active window.
    #
    def type(str)
      automatically "type #{str}"
    end

    # Sends the keycode (a hex value) to the active control in the active 
    # window. For more about keycode values, see Mac Developer documentation.
    #
    def hit(key)
      automatically "hit #{key}"
    end

    # Don't do anything for the specified number of seconds (can be portions
    # of a second).
    #
    def pause(seconds)
      sleep seconds
    end

    # Use Leopard's native text-to-speech functionality to emulate a human
    # voice saying the narrative text.
    #
    def say(narrative, voice = nil)
			if voice_exist?(voice)
					run(%Q`say -v #{voice} #{escape_dq(narrative)}`)
			else
	      run(%Q`say "#{escape_dq(narrative)}"`)
			end
    end

    # Starts saying the narrative text, and simultaneously begins executing
    # the given block. Waits until both are finished.
    #
    def while_saying(narrative, voice = nil)
      if block_given?
        fork { say(narrative, voice) }
        yield
        Process.wait
      else
        say(narrative)
      end
    end

    # Get a hash representing specific screen co-ordinates. Use in combination
    # with cursor, drag, launch, and similar methods.
    #
    def to(l, t, w = nil, h = nil)
      result = {
        :to => {
          :left => l,
          :top => t
        }
      }
      result[:to][:width] = w if w
      result[:to][:height] = h if h
      result
    end

    alias :at :to

    # Get a hash representing specific screen co-ordinates *relative to the
    # current mouse location.
    #
    def by(x, y)
      unless @cursor_loc
        @cursor_loc = automatically("mouselocation").strip.split(' ')
        @cursor_loc = {:x => @cursor_loc[0].to_i, :y => @cursor_loc[1].to_i}
      end
      to(@cursor_loc[:x] + x, @cursor_loc[:y] + y)
    end

    # The result of this method can be added +to+ a co-ordinates hash, 
    # offsetting the top and left values by the given margins.
    #
    def offset(x, y)
      { :offset => { :x => x, :y => y } }
    end


    # Returns a region hash describing the entire screen area. (May be wonky
    # for multi-monitor set-ups.)
    #
    def screen_size
      coords = execute_applescript(%Q`
        tell application "Finder"
            get bounds of window of desktop
        end tell
      `)
      coords = coords.split(", ").collect {|c| c.to_i}
      to(*coords)
    end

    # Runs a shell command, performing fairly naive (but effective!) exit 
    # status handling. Returns the stdout result of the command.
    #
    def run(cmd)
      #puts("Executing: #{cmd}")
      result = `#{cmd}`
      raise Castanaut::Exceptions::ExternalActionError if $?.exitstatus > 0
      result
    end
  
    # Adds custom methods to this movie instance, allowing you to perform
    # additional actions. See the README.txt for more information.
    #
    def plugin(str)
      str.downcase!
      begin
        require File.join(File.dirname(@screenplay_path),"plugins","#{str}.rb")
      rescue LoadError
        require File.join(LIBPATH, "plugins", "#{str}.rb")
      end
      extend eval("Castanaut::Plugin::#{str.capitalize}")
    end

    # Loads a script from a file into a string, looking first in the
    # scripts directory beneath the path where Castanaut was executed,
    # and falling back to Castanaut's gem path.
    #
    def script(filename)
      @cached_scripts ||= {}
      unless @cached_scripts[filename]
        fpath = File.join(File.dirname(@screenplay_path), "scripts", filename)
        scpt = nil
        if File.exists?(fpath)
          scpt = IO.read(fpath)
        else
          scpt = IO.read(File.join(PATH, "scripts", filename))
        end
        @cached_scripts[filename] = scpt
      end

      @cached_scripts[filename]
    end

    # This stage direction is slightly different to the other ones. It collects
    # a set of directions to be executed when the movie ends, or when it is
    # aborted by the user. Mostly, it's used for cleaning up stuff. Here's
    # an example:
    #
    #   ishowu_start_recording
    #   at_end_of_movie do
    #     ishowu_stop_recording
    #   end
    #   move to(100, 100) # ... et cetera
    #
    # You can use this multiple times in your screenplay -- remember that if
    # the movie is aborted by the user before this direction is used, its
    # contents won't be executed. So in general, create an at_end_of_movie
    # block after every action that you want to revert (like in the example
    # above).
    def at_end_of_movie(&blk)
      @end_credits ||= []
      @end_credits << blk
    end

		# test to see if this voice is available
		#
		def voice_exist?(voice_name)
			voice_names.include?(camelcase(voice_name))
		end
		
		# list all the voice names available from OS X
		#
		def voice_names
			@cached_voice_names = get_system_vioce_names if @cached_voice_names.nil?
			@cached_voice_names
		end
		
		# disaplay usage information
		#
		def usage(status, msg = nil)
			  output = (status == 0 ? $stdout : $stderr)
			  output.puts msg if msg
			  output.print(<<EOS)
Usage: #{File.basename $0} [screenplayfile]

=== Writing screenplays
You write your screenplays as Ruby files. Castanaut has been designed to 
read fairly naturally to the non-technical, within Ruby's constraints.

Here's a simple screenplay:
  plugin "safari"
  launch "Safari", at(32, 32, 800, 600)
  url "http://www.google.com"
  pause 4
  move to_element('input[name="q"]')
  click
  type "Castanaut"
  move to_element('input[type="submit"]')
  click
  pause 4
  say "Oh. I was hoping for more results."
  say "Infact it looks good!", "Whisper"
=== Available system voices
#{voice_names.inspect}
=== You are listening voice "Cellos" now if available on your system.
EOS
				say "Dum dum dum dum dum dum dum he he he ho ho ho fa lah lah lah lah lah lah fa lah full hoo hoo hoo", "Cellos"
				say "Sorry if your speaker is too loud.", "whisper"
			  exit status
		end

    protected

			# return the camel case of the given string
			#
		  def camelcase(name)
				return if name.nil?
		    str = name.downcase.dup
		    str.gsub!(/(?:_+|-+)([a-z])/){ $1.upcase }
		    str.gsub!(/(\A|\s)([a-z])/){ $1 + $2.upcase }
		    str
		  end

			# I would like to give the credit to Martin Michel
			# -- returning a list containing the names of the system voices currently
			# -- installed on the Mac OS X system
			# -- >>> using a Python script named «sysvoices.py» to accomplish my task
			#
			def get_system_vioce_names
				py_script = File.join(PATH, "scripts", "sysvoices.py")
				names = execute_applescript(%Q`
					set pyscriptpath to POSIX path of ("#{py_script}")
					set command to "/usr/bin/python " & quoted form of pyscriptpath
					set command to command as «class utf8»
					set sysvoicenames to paragraphs of (do shell script command)
					return sysvoicenames
				`)
				names.chop.split(', ')
			end

      def execute_applescript(scpt)
        File.open(FILE_APPLESCRIPT, 'w') {|f| f.write(scpt)}
        result = run("osascript #{FILE_APPLESCRIPT}")
        File.unlink(FILE_APPLESCRIPT)
        result
      end

      def automatically(cmd)
        run("#{osxautomation_path} \"#{cmd}\"")
      end

      def escape_dq(str)
        str.gsub(/\\/,'\\\\\\').gsub(/"/, '\"')
      end

      def combine_options(*args)
        options = args.inject({}) { |result, option| result.update(option) }
      end

    private
      def osxautomation_path
        File.join(PATH, "cbin", "osxautomation")
      end

      def perms_test
        return if File.executable?(osxautomation_path)
        puts "IMPORTANT: Castanaut has recently been installed or updated. " +
          "You need to give it the right to control mouse and keyboard " +
          "input during screenplays."

        run("sudo chmod a+x #{osxautomation_path}")

        if File.executable?(osxautomation_path)
          puts "Permission granted. Thanks."
        else
          raise Castanaut::Exceptions::OSXAutomationPermissionError
        end
      end

      def apply_offset(options)
        return unless options[:to] && options[:offset]
        options[:to][:left] += options[:offset][:x] || 0
        options[:to][:top] += options[:offset][:y] || 0
      end

      def mouse_button_translate(btn)
        return btn if btn.is_a?(Integer)
        {"left" => 1, "right" => 2, "middle" => 3}[btn]
      end

      def roll_credits
        return unless @end_credits && @end_credits.any?
        @end_credits.each {|credit| credit.call}
      end
      
  end
end
