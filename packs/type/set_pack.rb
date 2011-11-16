class Wagn::Renderer
  @@setting_group_title = {
    :perms   => 'Permission',
    :look    => 'Look and Feel',
    :com     => 'Communication',
    :other   => 'Other',
    :pointer => 'Pointer'
  }
  
  define_view(:core , :type=>'set') do |args|
    headings = ['Content','Type']
    setting_groups = card.setting_names_by_group
=begin    
    header= content_tag(:tr, :class=>'set-header') do
      content_tag(:th, :colspan=>(headings.size+1)) do
        count = card.count
        span(:class=>'set-label') { card.label } +
        span(:class=>'set-count') do
          raw( ' (' + (count == 1 ? link_to_page('1', card.item_names.first) : count.to_s) + ') ' )
        end + "\n" +
        (count<2 ? '' : span(:class=>'set-links') do
          raw(
            ' list by: ' + 
            [:name, :create, :update].map do |attrib|
              link_to_page( raw(attrib.to_s), "#{card.name}+by_#{attrib}")
            end.join( "\n" )
          )
        end)
      end 
    end
=end
    body = [:perms, :look, :com, :pointer, :other].map do |group|
      
      next unless setting_groups[group]
      content_tag(:tr, :class=>"rule-group") do
        (["#{@@setting_group_title[group.to_sym]} Settings"]+headings).map do |heading|
          content_tag(:th, :class=>'rule-heading') { heading }
        end.join("\n")
      end +
      raw( setting_groups[group].map do |setting_name| 
        rule_card = Card.fetch_or_new "#{card.name}+#{setting_name}", :skip_virtual=>true
        process_inclusion(rule_card, :view=>:closed_rule)
      end.join("\n"))
    end.compact.join

    content_tag('table', :class=>'set-rules') { body }
    
  end


  define_view(:edit, :type=>'set') do |args|
    'Cannot currently edit Sets' #ENGLISH
  end

  alias_view(:closed_content , {:type=>:search}, {:type=>:set})

end
