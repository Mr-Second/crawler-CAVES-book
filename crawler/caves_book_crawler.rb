require 'crawler_rocks'
require 'pry'
require 'json'
require 'iconv'
require 'isbn'
require 'book_toolkit'

require 'thread'
require 'thwait'

class CavesBookCrawler
  include CrawlerRocks::DSL

  ATTR_HASH = {
    "料號(EAN)" => :ean,
    "ISBN" => :isbn,
    "作 者" => :author,
    "出 版 社" => :publisher,
  }

  def initialize update_progress: nil, after_each: nil
    @update_progress_proc = update_progress
    @after_each_proc = after_each

    @index_url = "http://www.cavesbooks.com.tw/EC/"
  end

  def books
    @books = {}
    @page_threads = []
    @detail_threads = []

    visit @index_url

    first_level_categories = Hash[ @doc.css('a.leftMenuStyle').map{|a|
      [ a.text, URI.join(@index_url, a[:href]).to_s ]
    }]

    # 真是有病的寫法 XDD
    second_level_categories = %w(.menu_body .menu_head).map{|klass| Hash[ @doc.css("#{klass} a").map{|a| [a.text.tr('‧','') , URI.join(@index_url, a[:href]).to_s ] } ] }.inject{|arr, nxt| arr.merge(nxt) }

    second_level_categories.each do |category_name, category_url|
      # category_url = second_level_categories[category_name]
      print "start category: #{category_name}\n"
      r = RestClient.get category_url
      doc = Nokogiri::HTML(r)

      page_num = doc.css('a').map{|a| a[:href] }.select{|a| a && a.match(/PG=\d+/) }.map{|a| a.match(/PG=(\d+)/)[1].to_i}.max

      parse_book_list(doc)

      (2..page_num).each do |i|
        sleep(1) until (
          @page_threads.delete_if { |t| !t.status };  # remove dead (ended) threads
          @page_threads.count < (ENV['MAX_THREADS'] || 10)
        )
        @page_threads << Thread.new do
          r = RestClient.get "#{category_url}&PG=#{i}"
          doc = Nokogiri::HTML(r)

          parse_book_list(doc)
        end
      end if page_num && page_num > 1

    end
    ThreadsWait.all_waits(*@page_threads)
    ThreadsWait.all_waits(*@detail_threads)

    @books.values
  end

  def parse_book_list doc
    doc.xpath('//ul[@class="booksList"]/li').each do |list_item|
      # external_image_url = URI.join(@index_url, list_item.xpath('div[@class="booksListL"]/a/img/@src').to_s).to_s
      url = URI.join(@index_url,  list_item.xpath('div[@class="booksListL"]/a/@href').to_s).to_s
      original_price = list_item.xpath('div[@class="booksListR"]/div').text.match(/(?<=定   價：NT\s)\d+/).to_s.to_i
      name = list_item.xpath('div[@class="booksListC"]/h3/a').text

      author_pub_str = list_item.xpath('div[@class="booksListC"]/h4').text.strip
      author = author_pub_str.rpartition('，')[0]
      publisher = author_pub_str.rpartition('，')[-1]

      @books[url] = {
        name: name,
        url: url,
        original_price: original_price,
        author: author,
        publisher: publisher,
        known_supplier: 'caves'
      }

      parse_book_detail(url)
    end
  end

  def parse_book_detail url
    sleep(1) until (
      @detail_threads.delete_if { |t| !t.status };  # remove dead (ended) threads
      @detail_threads.count < (ENV['MAX_THREADS'] || 30)
    )
    @detail_threads << Thread.new do
      r = RestClient.get url
      doc = Nokogiri::HTML(r)

      doc.css('.bookDateBox tr').map{ |tr| tr.text.strip }.each do |attr_data|
        key = attr_data.rpartition('：')[0]
        @books[url][ATTR_HASH[key]] = attr_data.rpartition('：')[-1].strip if ATTR_HASH[key]
      end

      @books[url][:isbn].gsub!(/-/, '')

      begin
        @books[url][:isbn] = BookToolkit.to_isbn13(@books[url][:isbn])
      rescue Exception => e
        @books[url][:isbn] = nil
      end
      @after_each_proc.call(book: @books[url]) if @after_each_proc
      # print "|"
    end
  end

  def save_temp r
    File.write('tmp.html', r)
  end

end

# cc = CavesBookCrawler.new
# File.write('caves_book.json', JSON.pretty_generate(cc.books))
