class Wagn::Renderer
  ### ---- Core renders --- Keep these on top for dependencies

  # update_references based on _render_refs, which is the same as
  # _render_raw, except that you don't need to alias :refs as often
  # speeding up the process when there can't be any reference changes
  # (builtins, etc.)

  define_view :raw      do |args|  card ? card.raw_content : _render_blank                          end
  define_view :refs     do |args|  card.respond_to?('references_expired') ? card.raw_content : ''   end
  define_view :core     do |args|  process_content _render_raw                                      end
  define_view :content  do |args|  _render_core                                                     end
    # this should be done as an alias, but you can't make an alias with an unknown view, 
    # and base renderer doesn't know "content" at this point
  define_view :titled   do |args|  card.name + "\n\n" + _render_core                                end
  define_view :show     do |args|  render( args[:view] || params[:view] || :core )                  end
  define_view :name     do |args|  card.name                                                        end
  define_view :key      do |args|  card.key                                                         end
  define_view :id       do |args|  card.id                                                          end
  define_view :linkname do |args|  card.cardname.to_url_key                                         end
  define_view :link     do |args|  name=card.name; build_link(name, name, card.known?)              end
  define_view :url      do |args|  wagn_url _render_linkname                                        end    

  define_view :open_content do |args|
    pre_render = _render_core(args) { yield args }
    card ? card.post_render(pre_render) : pre_render
  end

  define_view :closed_content do |args|
    truncatewords_with_closing_tags _render_core(args) { yield }
  end

###----------------( SPECIAL )
  define_view :array do |args|
    if card.collection?
      card.item_cards(:limit=>0).map do |item_card|
        subrenderer(item_card)._render_core
      end
    else
      [ _render_core(args) { yield } ]
    end.inspect
  end

  define_view :blank do |args| "" end


  define_view :not_found do |args|
    %{ There's no card named "#{card.name}" }
  end


  define_view :server_error do |args|
    %{ Wagn Hitch!  Server Error. Yuck, sorry about that.\n}+
    %{ To tell us more and follow the fix, add a support ticket at http://wagn.org/new/Support_Ticket }
  end

  define_view :denial do |args|
    args[:denied_view] ? '' : 'Permission Denied' 
  end
  
  define_view :bad_address do |args|
    %{ Bad Address }
  end


  # The below have HTML!?  should not be any html in the base renderer


  define_view :edit_virtual do |args|
    %{ <div class="faint"><em>#{ @showname || card.name } is a Virtual card</em></div> }
  end

  define_view :closed_missing do |args|
    %{<span class="faint"> #{ @showname || card.name } </span>}
  end

  define_view :too_deep do |args|
    %{Man, you're too deep.  (Too many levels of inclusions at a time)}
  end

  define_view :too_slow do |args|
    %{<span class="too-slow">Timed out! #{ card.name } took too long to load.</span>}
  end
end
