module Wagn::Model::TrackedAttributes 
   
  def set_tracked_attributes
    #Rails.logger.debug "Card(#{name})#set_tracked_attributes begin"
    @was_new_card = self.new_card?
    updates.each_pair do |attrib, value| 
      #Rails.logger.debug "updates #{attrib} = #{value}"
      if send("set_#{attrib}", value )
        updates.clear attrib
      end
      @changed ||={}; @changed[attrib.to_sym]=true 
    end
    #Rails.logger.debug "Card(#{name})#set_tracked_attributes end"
  end
  
  
  # this method conflicts with ActiveRecord since Rails 2.1.0
  # the only references I see are in cache_spec, so removing for now
=begin    
  def changed?(field) 
    #return false
    #if updates.emtpy?
    @changed ||={}; 
    #warn "GET CHAGNED #{field.inspect}"    
    !!(@changed[field] && !updates.for?(field))
  end
=end
  
  protected 
  def set_name(newname)
    if (@old_name = self.name_without_tracking) != newname.to_s
      @cardname, name_without_tracking =
         Wagn::Cardname===newname ? [newname, newname.to_s] :
                                    [newname.to_cardname, newname]
      write_attribute :key, k=cardname.to_key
      write_attribute :name, name_without_tracking # what does this do?
    else return end

    raise "No name ???" if name.blank? # this should not pass validation.
    Wagn::Cache.expire_card(cardname.to_key)

    if @cardname.junction?
      [:trunk, :tag].each do |side|
        sidename = @cardname.send "#{side}_name"
        sidecard = Card[sidename]
        old_name_in_way = (sidecard && sidecard.id==self.id) # eg, renaming A to A+B
        suspend_name(sidename) if old_name_in_way
        self.send "#{side}=", (!sidecard || old_name_in_way ? Card.create!(:name=>sidename) : sidecard)
      end
    else
      self.trunk = self.tag = nil
    end   

    return if new_card?
    if existing_card = Card.find_by_key(@cardname.to_key) and existing_card != self
      if existing_card.trash  
        existing_card.name = tr_name = existing_card.name+'*trash'
        existing_card.instance_variable_set :@cardname, tr_name.to_cardname
        existing_card.set_tracked_attributes
        Rails.logger.debug "trash renamed collision: #{tr_name}, #{existing_card.name}, #{existing_card.cardname.key}"
        existing_card.update_attributes! :confirm_rename=>true
      #else note -- else case happens when changing to a name variant.  any special handling needed?
      end
    end
          
    Cardtype.cache.reset if typecode=='Cardtype'
    Wagn::Cache.expire_card(@old_name.to_cardname.key)
    @name_changed = true          
    @name_or_content_changed=true
  end


  def suspend_name(name)
    # move the current card out of the way, in case the new name will require
    # re-creating a card with the current name, ie.  A -> A+B
    Wagn::Cache.expire_card(name.to_cardname.to_key)
    tmp_name = "tmp:" + UUID.new.generate      
    connection.update %{update cards set #{quoted_comma_pair_list(connection, {:name=>"'#{tmp_name}'",:key=>"'#{tmp_name}'"})} where id=#{self.id}}    
  end

  def set_typecode(new_typecode)
#    Rails.logger.debug "set_typecde No type code for #{name}, #{typecode}" unless new_typecode
    self.typecode_without_tracking = new_typecode
    return true if new_card?
    on_type_change # FIXME this should be a callback
    if hard_template? && !type_template?
      hard_templatee_names.each do |templatee_name|
        tee = Card[templatee_name]
        tee.allow_type_change = true  #FIXME? this is a hacky way around the standard validation
        tee.typecode = new_typecode
        tee.save!
      end
    end
    
    # do we need to "undo" and loaded modules?  Maybe reload defaults?
    singleton_class.include_type_module(typecode)
    reset_patterns
    true
  end
  
  def set_content(new_content)  
    return false unless self.id 
    new_content ||= '' 
    new_content = WikiContent.clean_html!(new_content) if clean_html?
    clear_drafts if current_revision_id
    self.current_revision = Revision.create :card_id=>self.id, :content=>new_content
    @name_or_content_changed = true
  end
           
  def set_comment(new_comment)    
    set_content( content + new_comment )
    true
  end
  
  def set_initial_content  
    #Rails.logger.debug "Card(#{name})#set_initial_content start"
    # set_content bails out if we call it on a new record because it needs the
    # card id to create the revision.  call it again now that we have the id.
    
    set_content updates[:content]
    updates.clear :content 
    # normally the save would happen after set_content. in this case, update manually:
    #Rails.logger.debug "set_initial_content #{current_revision_id} #{name}"
    connection.update(
      "update cards set current_revision_id=#{current_revision_id} where id=#{id}",
      "Card Update"
    )
    #Rails.logger.debug "Card(#{name})#set_initial_content end"
  end
  
  def cascade_name_changes 
    return true unless @name_changed
    ActiveRecord::Base.logger.info("----------------------- CASCADE #{self.name}  -------------------------------------")  
    
    deps = self.dependents
                                          
    deps.each do |dep|
      ActiveRecord::Base.logger.info("---------------------- DEP #{dep.name}  -------------------------------------")  
      cxn = ActiveRecord::Base.connection
      depname = dep.cardname.replace_part(@old_name, name)
      depkey = depname.to_key
      # here we specifically want NOT to invoke recursive cascades on these cards, have to go this 
      # low level to avoid callbacks.
      
      # FIXME! in response to the old comment above: um.... why not?
      # I think we need the validations and the updates to recurse.
      # it may be that we want to send certain args along to prevent certain callbacks, but this is too hacky, and it's
      # tied to at least one bug: if any of the names in the update below are in the trash, the whole thing explodes.
      # would be surprised if there weren't also caching bugs stemming from this.
      # I trust the above actually avoided some issues, but we need to nail those down, test, and fix them
      # EFM - 5/21/12
      Card.update_all("name=#{cxn.quote(depname.to_s)}, #{cxn.quote_column_name("key")}=#{cxn.quote(depkey)}", "id = #{dep.id}")
      dep.expire(dep)
    end 

    if !update_referencers || update_referencers == 'false'  # FIXME doing the string check because the radio button is sending an actual "false" string
      #warn "no updating.."
      ([self]+deps).each do |dep|
        ActiveRecord::Base.logger.info("--------------- NOUPDATE REFERRER #{dep.name}  ---------------------------")
        WikiReference.update_on_destroy(dep, @old_name) 
      end
    else
      User.as(:wagbot) do
        [self.name_referencers(@old_name)+(deps.map &:referencers)].flatten.uniq.each do |card|
          # FIXME  using "name_referencers" instead of plain "referencers" for self because there are cases where trunk and tag
          # have already been saved via association by this point and therefore referencers misses things
          # eg.  X includes Y, and Y is renamed to X+Z.  When X+Z is saved, X is first updated as a trunk before X+Z gets to this point.
          # so at this time X is still including Y, which does not exist.  therefore #referencers doesn't find it, but name_referencers(old_name) does.
          # some even more complicated scenario probably breaks on the dependents, so this probably needs a more thoughtful refactor
          # aligning the dependent saving with the name cascading
          
          ActiveRecord::Base.logger.info("------------------ UPDATE REFERRER #{card.name}  ------------------------")
          next if card.hard_template
          card.content = Wagn::Renderer.new(card, :not_current=>true).replace_references( @old_name, name )
          card.save! unless card==self
        end
      end
    end

    WikiReference.update_on_create( self )
    @name_changed = false   
    true
  end
             
  def self.included(base)
    super 
    base.after_create :set_initial_content 
    base.after_save :cascade_name_changes
  end    

end
