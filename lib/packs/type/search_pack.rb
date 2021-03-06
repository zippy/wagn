class Wagn::Renderer
  define_view :core, :type=>'search' do |args|
    error=nil
    results = begin
      card.item_cards( search_params )
    rescue Exception=>e
      error = e; nil
    end

    case
    when results.nil?
      Rails.logger.debug error.backtrace
      %{No results? #{error.class.to_s}: #{error&&error.message}<br/>#{card.content}}
    when card.spec[:return] =='count'
      results.to_s
    else
      _render_card_list args.merge( :results=>results )
    end
  end
  
  define_view :editor, :type=>'search' do |args|
    form.text_area :content, :rows=>10
  end

  define_view :closed_content, :type=>'search' do |args|
    return "..." if @depth > 2
    results= begin
      card.item_cards( search_params )
    rescue Exception=>e
      error = e; nil
    end

    if results.nil?
      %{"#{error.class.to_s}: #{error.message}"<br/>#{card.content}}
    elsif card.spec[:return] =='count'
      results.to_s
    elsif results.length==0
      '<span class="search-count">(0)</span>'
    else
      %{<span class="search-count">(#{ card.count })</span>
      <div class="search-result-list">
        #{results.map do |c|
          %{<div class="search-result-item">#{@item_view == 'name' ? c.name : link_to_page( c.name ) }</div>}
        end*"\n"}
      </div>}
    end
  end

  define_view :card_list, :type=>'search' do |args|
    @item_view ||= (card.spec[:view]) || :closed
    paging = _optional_render :paging, args

    _render_search_header +
    if args[:results].empty?
      %{<div class="search-no-results"></div>}
    else
      %{
      #{paging}
      <div class="search-result-list"> #{
      args[:results].map do |c|
        %{<div class="search-result-item item-#{ @item_view }">
          #{ process_inclusion c, :view=>@item_view }
        </div>}
      end.join }
      </div>
      #{ paging if args[:results].length > 10 }
      }
    end
  end
  
  define_view :search_header do |args|
    ''
  end

  define_view :search_header, :name=>'*search' do |args|
    return '' unless vars = search_params[:vars] and keyword = vars[:keyword]
    %{<h1 class="page-header search-result-header">Search results for: <em>#{keyword}</em></h1>}
  end

  define_view :card_list, :name=>'*recent' do |args|
    cards = args[:results]
    @item_view ||= (card.spec[:view]) || :change

    cards_by_day = Hash.new { |h, day| h[day] = [] }
    cards.each do |card|
      begin
        stamp = card.updated_at
        day = Date.new(stamp.year, stamp.month, stamp.day)
      rescue Exception=>e
        day = Date.today
        card.content = "(error getting date)"
      end
      cards_by_day[day] << card
    end

    paging = _optional_render :paging, args
    
%{<h1 class="page-header">Recent Changes</h1>
<div class="open-view recent-changes">
  <div class="open-content">
    #{ paging }
  } +
    cards_by_day.keys.sort.reverse.map do |day| 
      
%{  <h2>#{format_date(day, include_time = false) }</h2>
    <div class="search-result-list">} +
         cards_by_day[day].map do |card| %{
      <div class="search-result-item item-#{ @item_view }">
           #{process_inclusion(card, :view=>@item_view) }
      </div>}
         end.join(' ') + %{
    </div>
    } end.join("\n") + %{    
      #{ paging }
  </div>
</div>
}
  end



  define_view :paging, :type=>'search' do |args|
    s = card.spec search_params
    offset, limit = s[:offset].to_i, s[:limit].to_i
    return '' if limit < 1
    return '' if offset==0 && limit > offset + args[:results].length #avoid query if we know there aren't enough results to warrant paging 
    total = card.count search_params
    return '' if limit >= total # should only happen if limit exactly equals the total
 
    @paging_path_args = { :limit => limit, :item  => ( @item_view || args[:item] ) }
    @paging_limit = limit
    
    s[:vars].each { |key, value| @paging_path_args["_#{key}"] = value }

    out = ['<span class="paging">' ]
    
    total_pages  = ((total-1) / limit).to_i
    current_page = ( offset   / limit).to_i # should already be integer
    window = 2 # should be configurable
    window_min = current_page - window
    window_max = current_page + window

    if current_page > 0
      out << page_link( '&laquo; prev', current_page - 1 )
    end

    out << %{<span class="paging-numbers">}
    if window_min > 0
      out << page_link( 1, 0 )
      out << '...' if window_min > 1
    end    
    
    (window_min .. window_max).each do |page|
      next if page < 0 or page > total_pages
      text = page + 1
      out <<  ( page==current_page ? text : page_link( text, page ) )
    end
    
    if total_pages > window_max
      out << '...' if total_pages > window_max + 1
      out << page_link( total_pages + 1, total_pages )
    end    
    out << %{</span>}
    
    if current_page < total_pages
      out << page_link( 'next &raquo;', current_page + 1 )
    end
    
    out << %{<span class="search-count">(#{total})</span></span>}
    out.join
  end
  
  def page_link text, page
    @paging_path_args[:offset] = page * @paging_limit
    " #{link_to raw(text), path(:view, @paging_path_args), :class=>'card-paging-link slotter', :remote => true} "
  end

  def paging_params
    if ajax_call? && @depth > 0
      {:default_limit=>20}  #important that paging calls not pass variables to included searches
    else
      @paging_params ||= begin
        s = {}
        [:offset,:vars].each{ |key| s[key] = params[key] }
        s[:offset] = s[:offset] ? s[:offset].to_i : 0
        if params[:limit]
          s[:limit] = params[:limit].to_i
        else
          s[:default_limit] = 20 #can be overridden by card value
        end
        s
      end
    end
  end
end
