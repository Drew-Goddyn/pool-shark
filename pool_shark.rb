require 'mechanize'
require "tty-prompt"
require "tty-link"
require "tty-spinner"
require "tty-box"
# require "tty-table"
require "tty-tree"
require "pastel"
require 'pry'
require 'drb/drb'


class PoolShark
  attr_reader :prompt, :pastel, :selected_family
  attr_accessor :agent

  POOLS = {
    "Britannia" => "britannia-pool",
    "Hillcrest" => "hillcrest-aquatic-centre",
    "Kerrisdale" => "kerrisdale-pool",
    "Vancouver aquatic centre" => "vancouver-aquatic-center",
    "Killarney" => "killarney-pool",
    "Lord byng" => "lord-byng-pool",
    "Renfrew" => "renfrew-pool",
    "Templeton park" => "templeton-pool"
  }

  def initialize
    @agent = Mechanize.new
    @prompt = TTY::Prompt.new
    @pastel = Pastel.new
  end

  def self.run
    shark = new
    DRb.start_service('druby://localhost:9999', shark)
    shark.welcome_message
    shark.setup
    shark.collect_answers
    shark.place_order
  end

  def welcome_message
    puts TTY::Box.info(<<~WELCOME)
      Welcome to pool shark!

      We're gonna try to book some swimming times for you. Unfortunately, the Vancouver parks website uses
      captcha technology meaning we can't fully automate the process. To get started, navigate
      #{TTY::Link.link_to("here", "https://ca.apm.activecommunities.com/vancouver/ActiveNet_Login")} and log
      into your account before proceeding.
    WELCOME
    puts
    prompt.keypress("Press Enter to once you've logged in...", keys: [:return])
  end

  def setup
    setup_spinners = TTY::Spinner::Multi.new("[:spinner] Setup")
    set_session(setup_spinners)
    test_session(setup_spinners)
    set_family_members(setup_spinners)
  end

  def set_session(setup_spinners)
    spinner = setup_spinners.register("[:spinner] Stealing session")
    spinner.auto_spin
    sleep 3
    session = `python session_stealer.py`.chomp
    if session.empty?
      spinner.error(pastel.red("Failed: your session is empty. Make sure you've logged in before running the script again."))
      exit

    else
      agent.cookie_jar << Mechanize::Cookie.new(domain: 'ca.apm.activecommunities.com', name: "JSESSIONID", value: session, path: '/vancouver')
      spinner.success
    end
  end

  def test_session(setup_spinners)
    spinner = setup_spinners.register("[:spinner] Testing session")
    spinner.auto_spin
    sleep 3
    account_page = agent.get("https://ca.apm.activecommunities.com/vancouver/ActiveNet_Home?FileName=accountoptions.sdi")
    signout_link = account_page.link_with(text: "Sign Out")
    if signout_link
      spinner.success
    else
      spinner.error(pastel.red("Failed: your session might have expired. Try re-logging in before running the script again."))
      exit

    end
  end

  def set_family_members(setup_spinners)
    spinner = setup_spinners.register "[:spinner] Retrieving family members"
    spinner.auto_spin
    sleep 3
    family_page = agent.get("https://ca.apm.activecommunities.com/vancouver/ActiveNet_Home/ChangeFamilyMember.sdi")
    family_members = family_page.links_with(href: /changeFamilyMember|ChangeAddress/).map(&:text)
    if family_members
      @available_family = family_members
      spinner.success
    else
      spinner.error(pastel.red("Failed: you have no family members. Navigate to #{TTY::Link.link_to("here", "https://ca.apm.activecommunities.com/vancouver/ActiveNet_Home/ChangeFamilyMember.sdi")} to add them before running the script again."))
      exit

    end
  end

  def collect_answers
    @selected_family = prompt.multi_select("What family members would you like to book for?", @available_family, min: 1)
    loop do
      @pool = prompt.select("What pool would you like to book for?", POOLS.keys)
      @swim_type = prompt.select("What swim type would you like to do?", get_available_swim_types)
      @available_or_upcoming = prompt.select("Would you like to book a slot thats currently available or snag an upcoming one?", ["Available", "Upcoming"])

      if @available_or_upcoming == "Available"
        @swim_times = get_available_swim_times
        if @swim_times.keys.any?
          @selected_swim_time = prompt.select("What time would you like to swim?", @swim_times.keys)
          break

        else
          puts Pastel.red("Oops, it doesn't look like there's any available #{@swim_type} swim times for #{@pool}")
          continue = prompt.yes?("would you like to try another pool or swim type?")
          break unless continue

        end
      else
        @swim_times = get_upcoming_swim_times
        if @swim_times.keys.any?
          @selected_swim_time = prompt.select("What time would you like to swim?", @swim_times.keys)
          break
        else
          puts Pastel.red("Oops, it doesn't look like there's any available #{@swim_type} times for #{@pool}")
          continue = prompt.yes?("would you like to try another pool or swim type?")
          break unless continue

        end
      end
    end
  end

  def pool_info_page
    @pool_info_page ||= agent.get("https://vancouver.ca/parks-recreation-culture/#{POOLS[@pool]}.aspx")
  end

  def get_available_swim_types
    pool_info_page.links_with(href: /Activity_Search/).map(&:text)
  end

  def get_available_swim_times
    swim_type = Regexp.escape(@swim_type.downcase.tr(" ","+"))
    activity_page = pool_info_page.link_with(href: /Activity_Search\?detailskeyword=#{swim_type}/).click
    available_cart_links = activity_page.links_with(text: "Add to Cart") #.map{ |link| link.href[/\d*$/] }
    available_cart_links.each_with_object({}) do |cart_link, hash|
      id = cart_link.href[/\d*$/]
      timeslot = activity_page.link_with(href: %r(https://ca.apm.activecommunities.com/vancouver/Activity_Search/.*-#{@swim_type.downcase.tr(" ", "-")}-.*/#{id})).text
      hash[timeslot] = cart_link
    end
  end

  def get_upcoming_swim_times
    swim_type = Regexp.escape(@swim_type.downcase.tr(" ","+"))
    activity_page = pool_info_page.link_with(href: /Activity_Search\?detailskeyword=#{swim_type}/).click
    wish_list_links = activity_page.links_with(text: "+ Wish List")
    return nil if wish_list_links.empty
    wish_list_links.each_with_object({}) do |cart_link, hash|
      id = cart_link.href[/\d*$/]
      timeslot = activity_page.link_with(href: %r(https://ca.apm.activecommunities.com/vancouver/Activity_Search/hillcrest-pool-public-swim-.*/#{id})).text.split.last(2).join(" ")
      hash[timeslot] = cart_link
    end
  end

  def place_order
    puts TTY::Box.warn("Were about to add a timeslot to your cart. Please review the order \non the right side of the screen before proceeding.")
    prompt.keypress(pastel.yellow("Press Enter to proceed..."), keys: [:return])
    if @available_or_upcoming == "Available"
      order_spinner = TTY::Spinner.new("[:spinner] Placing order", format: :pulse_2)
      order_spinner.auto_spin
      sleep 5
      order_spinner.success
      puts TTY::Box.success("Order placed, please navigate to your shopping cart to confirm.")
      # order_page = @swim_times[@selected_swim_time].click
      # family_member = @selected_family.shift
      # form = order_page.forms.find{|form| form.fields.find{|field| field.is_a?(Mechanize::Form::SelectList)}}
      # select_field = form.fields[1]

      # select_field.options.find { |option| option.text == family_member }.select

    else
    end
  end

  def show_table
    data = {
      "Family Members" => @selected_family,
      "Selected Pool" => @pool,
      "Selected swim type" => @swim_type,
      "Selected swim time" => @selected_swim_time
    }
    tree = TTY::Tree.new(data)
    TTY::Box.success(tree.render)

  end
end


PoolShark.run

DRb.thread.join
