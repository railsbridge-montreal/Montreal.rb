require "mysql2"
require "yaml"
require "nokogiri"
require "reverse_markdown"

namespace :database do
  desc 'Create a default user'
  task create_default_user: :environment do
    if User.default_user.present?
      puts 'The default user has already been created.'
    else
      User.create_default_user!
      puts 'The default user was created successfully.'
    end
  end

  desc 'Resets the counter cache of associations'
  task reset_counter_cache: :environment do
    Event.find_each { |event| Event.reset_counters(event.id, :talks) }
    Event.find_each { |event| Event.reset_counters(event.id, :sponsors) }
  end

  namespace :legacy do
    # NOTE to run remotely on heroku:
    # Source: https://devcenter.heroku.com/articles/rake
    #
    # $ heroku run rake database:legacy:import_news
    #
    desc "Import news records to database"
    task import_news: :environment do
      raise "Aborting import. First you must create the default user in the database. " \
        "See the 'database:create_default_user' rake task." if User.default_user.blank?

      STDOUT.puts "This will destroy your news_items table. Enter 'Y' to confirm: [y/N]"
      input = STDIN.gets.chomp
      raise "Aborting import. You entered #{input}" unless input.downcase == "y"

      NewsItem.destroy_all
      records = YAML.load_file "#{Rails.root}/db/legacy.yml"
      records.each do |data|
        news_item = NewsItem.new
        published_at = data["post_date"]

        news_item.state        = published_at > DateTime.new(2015, 1, 1).beginning_of_year ? :published : :archived
        news_item.title        = data["post_title"]
        news_item.body         = data["post_content"]
        news_item.published_at = data["post_date"]
        news_item.user_id      = User.default_user.id
        # url: http://www.montrealrb.com/[post_date:YYYY]/[post_date:MM]/[post_name]
        news_item.slug = data["post_name"]
        puts news_item.slug
        begin
          news_item.save!
        rescue => e
          puts e.message
          puts news_item.inspect
        end
      end
    end

    # NOTE: This has normally been run by someone with access to the wordpress mysql database dump
    # The result is `db/legacy.yml`
    desc "Generate a yml files with legacy news records from wordpress mysql DB"
    task dump: :environment do
      # database: montrealrb_wordpress
      # table: wp_posts
      # url: http://www.montrealrb.com/[post_date:YYYY]/[post_date:MM]/[post_name]
      client = Mysql2::Client.new(host: "localhost",
                                  username: "root",
                                  database: "montrealrb_wordpress")
      records = client.query("SELECT post_title, post_content, post_date, post_name
                             FROM wp_posts WHERE post_status='publish'")

      sanitized_records = records.to_a.map do |row|
        row.each do |k, v|
          next unless k.to_s == "post_content"
          doc = Nokogiri.HTML(v)
          # Remove weird avatars
          doc.css("img.alignleft").each do |el|
            el.replace("")
          end
          # Remove non breaking spaces
          nbsp = Nokogiri::HTML("&nbsp;").text
          clean_html_content = doc.to_html
          clean_html_content.gsub!(nbsp, " ")
          # Remove line breaks
          clean_html_content.gsub!("<br>", "")
          # Update HTML
          row[k] = ReverseMarkdown.convert clean_html_content
        end
      end
      File.open("#{Rails.root}/db/legacy.yml", "w") do |f|
        f.write sanitized_records.to_yaml
      end
    end
  end
end
