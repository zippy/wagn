# -*- encoding : utf-8 -*-
class Card < ActiveRecord::Base
  # FIXME:  this is ugly, but also useful sometimes... do in a more thoughtful way maybe?
  cattr_accessor :debug, :cache
  Card.debug = false

  belongs_to :trunk, :class_name=>'Card', :foreign_key=>'trunk_id' #, :dependent=>:dependent
  has_many   :right_junctions, :class_name=>'Card', :foreign_key=>'trunk_id'#, :dependent=>:destroy

  belongs_to :tag, :class_name=>'Card', :foreign_key=>'tag_id' #, :dependent=>:destroy
  has_many   :left_junctions, :class_name=>'Card', :foreign_key=>'tag_id'  #, :dependent=>:destroy

  belongs_to :current_revision, :class_name => 'Revision', :foreign_key=>'current_revision_id'
  has_many   :revisions, :order => 'id', :foreign_key=>'card_id'

  belongs_to :extension, :polymorphic=>true
  before_destroy :destroy_extension, :base_before_destroy
    
  attr_accessor :comment, :comment_author, :confirm_rename, :confirm_destroy, :update_referencers, :cards,
    :allow_type_change, :nested_edit, :virtual, :selected_rev_id, :error_view, :error_status, :loaded_trunk
 
  attr_reader :type_args, :broken_type

  before_save :base_before_save, :set_read_rule, :set_tracked_attributes, :set_extensions
  after_save :base_after_save, :update_ruled_cards
  cache_attributes 'name', 'typecode'

  @@junk_args = %w{ missing skip_virtual id }

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # INITIALIZATION METHODS
  
  def self.new args={}, options={}
    args = (args || {}).stringify_keys
    @@junk_args.each { |a| args.delete(a) }
    %w{ type typecode }.each { |k| args.delete(k) if args[k].blank? }
    args.delete('content') if args['attach'] # should not be handled here!

    if name = args['name'] and !name.blank?
      if cc= Card.cache.read_local(name.to_cardname.key)    and
          cc.type_args                                      and
          args['type']          == cc.type_args[:type]      and
          args['typecode']      == cc.type_args[:typecode]  and
          args['loaded_trunk']  == cc.loaded_trunk
          
        args['typecode'] = cc.typecode
        return cc.send( :initialize, args )
      end
    end
    super args
  end

  def initialize(args={})
    #Rails.logger.debug "initialize #{args.inspect}"
    
    args['name'] = args['name'].to_s  
    @type_args = { :type=>args.delete('type'), :typecode=>args['typecode'] }
    skip_modules = args.delete 'skip_modules'
    
    super args
    
    if !args['typecode']
      self.typecode_without_tracking = get_typecode(@type_args[:type]) 
    end
    
    include_set_modules unless skip_modules
    self
  end

  def new_card?()  new_record? || @from_trash  end
  def known?()    !(new_card? && !virtual?)    end
  
  def reset_mods() @set_mods_loaded=false      end

#private

  def get_typecode(typename=nil)
    if typename
      begin
        return Cardtype.classname_for(typename)
      rescue
        @broken_type = typename
      end
    end

    if name && t=template
      reset_patterns
      t.typecode
    else
      'Basic'
    end
  end


  def include_set_modules
    unless @set_mods_loaded
      @set_mods_loaded=true
      singleton_class.include_type_module typecode
    end
  end
  
  Wagn::Set::Type::HTML # this hack is needed in 1.8.1 because following is finding wrong constant (HTML, not Wagn::Set::Type::Html).
  #I believe this is fixed in traits branch
  def self.include_type_module typecode
    return unless typecode    
    root = Wagn::Set::Type
    if  root.const_defined?(  typecode )  and
        mod = root.const_get( typecode )  and 
        mod.to_s=="#{root}::#{typecode}"
      send :include, mod
    end
    
  end
  
  

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # SAVING

  def update_attributes(args={})
    if type = (args.delete(:type) || args.delete('type'))
      args[:typecode] = Cardtype.classname_for(type)
    end
    super args
  end

  def base_before_save
    if self.respond_to?(:before_save) and self.before_save == false
      errors.add(:save, "could not prepare card for destruction")
      return false
    end
  end

  def base_after_save
    save_subcards
    self.virtual = false
    @from_trash = false
    Wagn::Hook.call :after_create, self if @was_new_card
    send_notifications
    if self.typecode == 'Cardtype'
      Cardtype.cache.reset
    end
    true
  rescue Exception=>e
    @subcards.each{ |card| card.expire_pieces }
    Rails.logger.info "after save issue: #{e.message}"
    raise e
  end

  def save_subcards
    @subcards = []
    return unless cards
    cards.each_pair do |sub_name, opts|
      opts[:nested_edit] = self
      sub_name = sub_name.gsub('~plus~','+')
      absolute_name = cardname.to_absolute_name(sub_name)
      if card = Card[absolute_name]
        card = card.refresh if card.frozen?
        card.update_attributes opts
      elsif opts[:content].present? and opts[:content].strip.present?
        opts[:name] = absolute_name
        card = Card.create opts
      end
      @subcards << card if card
      if card and card.errors.any?
        card.errors.each do |field, err|
          self.errors.add card.name, err
        end
        raise ActiveRecord::Rollback
      end
    end
  end

  def set_extensions
    self.create_extension if !extension && respond_to?(:create_extension)
  end

  def save_with_trash!
    save || raise(errors.full_messages.join('. '))
  end
  alias_method_chain :save!, :trash

  def save_with_trash(*args)#(perform_checking=true)
    pull_from_trash if new_record?
    self.trash = !!trash
    save_without_trash(*args)#(perform_checking)
  end
  alias_method_chain :save, :trash

  def save_with_permissions(*args)  #checking is needed for update_attribute, evidently.  not sure I like it...
    Rails.logger.debug "Card#save_with_permissions!:"
    run_checked_save :save_without_permissions
  end
  alias_method_chain :save, :permissions
   
  def save_with_permissions!(*args)
    Rails.logger.debug "Card#save_with_permissions!"
    run_checked_save :save_without_permissions!
  end 
  alias_method_chain :save!, :permissions
  
  def run_checked_save(method)#, *args)
    if approved?
      begin
        self.send(method)
      rescue Exception => e
        rescue_save(e, method)
      end
    else
      raise Card::PermissionDenied.new(self)
    end
  end

  def rescue_save(e, method)
    expire_pieces
    Rails.logger.info "Model exception #{method}:#{e.message} #{name}"
    Rails.logger.debug e.backtrace*"\n"
    raise Wagn::Oops, "error saving #{self.name}: #{e.message}, #{e.backtrace*"\n"}"
  end

  def expire_pieces
    cardname.piece_names.each do |piece|
      Wagn::Cache.expire_card piece.to_cardname.key
    end
  end

  def pull_from_trash
    return unless key
    return unless trashed_card = Card.find_by_key_and_trash(key, true)
    #could optimize to use fetch if we add :include_trashed_cards or something.
    #likely low ROI, but would be nice to have interface to retrieve cards from trash...
    self.id = trashed_card.id
    @from_trash = self.confirm_rename = @trash_changed = true
    @new_record = false
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # DESTROY
 
  def destroy_with_trash(caller="")
    run_callbacks( :destroy ) do
      deps = self.dependents
      @trash_changed = true
      
      self.update_attribute(:trash, true) 
      deps.each do |dep|
        next if dep.trash #shouldn't be getting trashed cards
        dep.confirm_destroy = true
        dep.destroy_with_trash("#{caller} -> #{name}")
      end
      true
    end
  end
  alias_method_chain :destroy, :trash

  def destroy_with_validation
    errors.clear
    validate_destroy

    if !dependents.empty? && !confirm_destroy
      errors.add(:confirmation_required, "because #{name} has #{dependents.size} dependents")
    end

    dependents.each do |dep|
      dep.send :validate_destroy
      if !dep.errors[:destroy].empty?
        errors.add(:destroy, "can't destroy dependent card #{dep.name}: #{dep.errors[:destroy]}")
      end
    end

    errors.empty? ? destroy_without_validation : false
  end
  alias_method_chain :destroy, :validation

  def destroy!
    # FIXME: do we want to overide confirmation by setting confirm_destroy=true here?
    # This is aliased in Permissions, which could be related to the above comment
    self.confirm_destroy = true
    destroy or raise Wagn::Oops, "Destroy failed: #{errors.full_messages.join(',')}"
  end

  def destroy_extension
    extension.destroy if extension
    extension = nil
    true
  end
  
  def base_before_destroy
    self.before_destroy if respond_to? :before_destroy
  end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # NAME / RELATED NAMES


  # FIXME: use delegations and include all cardname functions
  def simple?()     cardname.simple?       end
  def junction?()   cardname.junction?     end
  def key()         cardname.key           end
  def css_name()    cardname.css_name      end

  def left()      Card[cardname.left_name]  end
  def right()     Card[cardname.tag_name]   end
  def pieces()    simple? ? [self] : ([self] + trunk.pieces + tag.pieces).uniq end
  def particles() cardname.particle_names.map{|name| Card.fetch name}          end
  def key()       cardname.key                                                 end

  def junctions(args={})
    return [] if new_record? #because lookup is done by id, and the new_records don't have ids yet.  so no point.
    args[:conditions] = ["trash=?", false] unless args.has_key?(:conditions)
    args[:order] = 'id' unless args.has_key?(:order)
    # aparently find f***s up your args. if you don't clone them, the next find is busted.
    left_junctions.find(:all, args.clone) + right_junctions.find(:all, args.clone)
  end

  def dependents(*args)
    # all plus cards, plusses of plus cards, etc
    jcts = junctions(*args)
    jcts.delete(self) if jcts.include?(self)
    return [] if new_record? #because lookup is done by id, and the new_records don't have ids yet.  so no point.
    jcts.map { |r| [r ] + r.dependents(*args) }.flatten
  end

  def codename
    return nil unless extension and extension.respond_to?(:codename)
    extension.codename
  end

  def repair_key
    ::User.as :wagbot do
      correct_key = cardname.to_key
      current_key = key
      return self if current_key==correct_key
      
      if key_blocker = Card.find_by_key_and_trash(correct_key, true)
        key_blocker.cardname = key_blocker.cardname + "*trash#{rand(4)}"
        key_blocker.save
      end

      saved =   ( self.key  = correct_key and self.save! )
      saved ||= ( self.cardname = current_key and self.save! )

      if saved
        self.dependents.each { |c| c.repair_key }
      else
        Rails.logger.debug "FAILED TO REPAIR BROKEN KEY: #{key}"
        self.name = "BROKEN KEY: #{name}"
      end
      self
    end
  rescue
    Rails.logger.debug "BROKE ATTEMPTING TO REPAIR BROKEN KEY: #{key}"
    self
  end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # TYPE

  def type_card
    ct = ::Cardtype.find_by_class_name( self.typecode )
    raise("Error in #{self.name}: No cardtype for #{self.typecode}")  unless ct
    ct.card
  end
  
  def typename() typecode and Cardtype.name_for( typecode ) or 'Basic' end
  def type=(typename)
    self.typecode = Cardtype.classname_for(typename) 
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # CONTENT / REVISIONS

  def content
    new_card? ? template(reset=true).content : cached_revision.content
  end
  
  def raw_content
    r = (t=templated_content) || (c=content)
    raise "???, #{name}, #{t}, #{c}" if r.nil? or r==false
    r
  end

  def selected_rev_id() @selected_rev_id || (cr=cached_revision)&&cr.id || 0 end

  def cached_revision
    #return current_revision || Revision.new
    case
    when (@cached_revision and @cached_revision.id==current_revision_id);
    when (@cached_revision=Revision.cache.read("#{cardname.css_name}-content") and @cached_revision.id==current_revision_id);
    else
      rev = current_revision_id ? Revision.find(current_revision_id) : Revision.new
      @cached_revision = Revision.cache.write("#{cardname.css_name}-content", rev)      
    end
    @cached_revision
  end

  def previous_revision(revision)
    rev_index = revisions.each_with_index do |rev, index| 
      rev.id == revision.id ? (break index) : nil 
    end
    (rev_index.nil? || rev_index==0) ? nil : revisions[rev_index - 1]
  end
   
  def revised_at
    (cached_revision && cached_revision.created_at) || Time.now
  end

  def updater
    User[updated_by]
  end

  def drafts
    revisions.find(:all, :conditions=>["id > ?", current_revision_id])
  end
         
  def save_draft( content )
    clear_drafts
    revisions.create(:content=>content)
  end

  protected
  def clear_drafts
    connection.execute(%{delete from revisions where card_id=#{id} and id > #{current_revision_id} })
  end
  
  public
  

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # METHODS FOR OVERRIDE

  def post_render( content )     content  end
  def clean_html?()                 true  end
  def collection?()                false  end
  def on_type_change()                    end
  def validate_type_change()        true  end
  def validate_content( content )         end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # MISCELLANEOUS
  
  def to_s()  "#<#{self.class.name}[#{self.typename.to_s}]#{self.attributes['name']}>" end
  def inspect()  "#<#{self.class.name}[#{self.typecode}]#{self.name}{n:#{new_card?}v:#{virtual}:I:#{@set_mods_loaded}:#{object_id}:r:#{current_revision_id}}:#{@set_names.inspect}>" end
  def mocha_inspect()     to_s                                   end

#  def trash
    # needs special handling because default rails cache lookup uses `@attributes_cache['trash'] ||=`, which fails on "false" every time
#    ac= @attributes_cache
#    ac['trash'].nil? ? (ac['trash'] = read_attribute('trash')) : ac['trash']
#  end





  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # INCLUDED MODULES

  include Wagn::Model

  after_save :after_save_hooks
  # moved this after Wagn::Model inclusions because aikido module needs to come after Paperclip triggers,
  # which are set up in attach model.  CLEAN THIS UP!!!

  def after_save_hooks # don't move unless you know what you're doing, see above.
    Wagn::Hook.call :after_save, self
  end

  #bail out when not recording userstamps (eg updating read rule)
  skip_callback :save, :after, :after_save_hooks, :save_attached_files,
   :if => lambda { !Card.record_userstamps }

  # Because of the way it chains methods, 'tracks' needs to come after
  # all the basic method definitions, and validations have to come after
  # that because they depend on some of the tracking methods.
  tracks :name, :typecode, :content, :comment

  # this method piggybacks on the name tracking method and
  # must therefore be defined after the #tracks call


  def cardname() @cardname ||= name_without_cardname.to_cardname end

  alias cardname= name=
  def name_with_cardname=(newname)
    newname = newname.to_s
    if name != newname
      @cardname = nil
      updates.add :name, newname
      reset_patterns
    else
      name
    end
  end
  alias_method_chain :name=, :cardname
  def cardname() @cardname ||= name.to_cardname end
  
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # VALIDATIONS

  def validate_destroy    
    if extension_type=='User' and extension and Revision.find_by_created_by( extension.id )
      errors.add :destroy, "Edits have been made with #{name}'s user account.<br>  Deleting this card would mess up our revision records."
      return false
    end           
    #should collect errors from dependent destroys here.  
    true
  end
  
  protected
  
  validate do |rec|
    return true if @nested_edit
    return true unless Wagn::Conf[:recaptcha_on] && Card.toggle( rec.rule('captcha') )
    c = Wagn::Conf[:controller]
    return true if (c.recaptcha_count += 1) > 1
    c.verify_recaptcha( :model=>rec ) || rec.error_status = 449
  end
  
#  validates_presence_of :name
  validates_associated :extension #1/2 ans:  this one runs the user validations on user cards.

  validates_each :name do |rec, attr, value|
    if rec.new_card? && value.blank?
      if autoname_card = rec.rule_card('autoname')
        User.as(:wagbot) do
          autoname_card = autoname_card.refresh if autoname_card.frozen?
          value = rec.name = Card.autoname(autoname_card.content)
          autoname_card.content = value  #fixme, should give placeholder on new, do next and save on create
          autoname_card.save!
        end
      end
    end

    cdname = value.to_cardname
    if cdname.blank?
      rec.errors.add :name, "can't be blank"
    elsif rec.updates.for?(:name)
      #Rails.logger.debug "valid name #{rec.name.inspect} New #{value.inspect}"
      
      
      unless cdname.valid?
        rec.errors.add :name,
          "may not contain any of the following characters: #{
          Wagn::Cardname::CARDNAME_BANNED_CHARACTERS}"
      end
      # this is to protect against using a junction card as a tag-- although it is technically possible now.
      if (cdname.junction? and rec.simple? and rec.left_junctions.size>0)
        rec.errors.add :name, "#{value} in use as a tag"
      end

      # validate uniqueness of name
      condition_sql = "cards.key = ? and trash=?"
      condition_params = [ cdname.to_key, false ]
      unless rec.new_record?
        condition_sql << " AND cards.id <> ?"
        condition_params << rec.id
      end
      if c = Card.find(:first, :conditions=>[condition_sql, *condition_params])
        rec.errors.add :name, "must be unique-- A card named '#{c.name}' already exists"
      end

      # require confirmation for renaming multiple cards
      if !rec.confirm_rename
        pass = true
        if !rec.dependents.empty?
          pass = false
          rec.errors.add :confirmation_required, "#{rec.name} has #{rec.dependents.size} dependents"
        end

        if rec.update_referencers.nil? and !rec.extended_referencers.empty?
          pass = false
          rec.errors.add :confirmation_required, "#{rec.name} has #{rec.extended_referencers.size} referencers"
        end
        
        if !pass
          rec.error_view = :edit
          rec.error_status = 200 #I like 401 better, but would need special processing
        end
      end
    end
  end

  validates_each :content do |rec, attr, value|
    if rec.new_card? && !rec.updates.for?(:content)
      value = rec.content = rec.content #this is not really a validation.  is the double rec.content meaningful?  tracked attributes issue?
    end
    
    if rec.updates.for? :content
      rec.send :validate_content, value
    end
  end

  validates_each :current_revision_id do |rec, attrib, value|
    if !rec.new_card? && rec.current_revision_id_changed? && value.to_i != rec.current_revision_id_was.to_i
      rec.current_revision_id = rec.current_revision_id_was
      rec.errors.add :conflict, "changes not based on latest revision"
      rec.error_view = :conflict
      rec.error_status = 409
    end
  end

  validates_each :typecode do |rec, attr, value|
    # validate on update
    if rec.updates.for?(:typecode) and !rec.new_card?
      if !rec.validate_type_change
        rec.errors.add :type, "of #{ rec.name } can't be changed; errors changing from #{ rec.typename }"        
      end
      if c = Card.new(:name=>'*validation dummy', :typecode=>value, :content=>'') and !c.valid?
        rec.errors.add :type, "of #{ rec.name } can't be changed; errors creating new #{ value }: #{ c.errors.full_messages.join ', ' }"
      end      
    end

    # validate on update and create
    if rec.updates.for?(:typecode) or rec.new_record?
      # invalid type recorded on create
      if rec.broken_type
        rec.errors.add :type, "won't work.  There's no cardtype named '#{rec.broken_type}'"
      end
      # invalid to change type when type is hard_templated
      if (rt = rec.right_template and rt.hard_template? and 
        value!=rt.typecode and !rec.allow_type_change)
        rec.errors.add :type, "can't be changed because #{rec.name} is hard tag templated to #{rt.typename}"
      end        
    end
  end

  validates_each :key do |rec, attr, value|
    if value.empty?
      rec.errors.add :key, "cannot be blank"
    elsif value != rec.cardname.to_key
      rec.errors.add :key, "wrong key '#{value}' for name #{rec.name}"
    end
  end
 
  class << self  
    def setting name
      User.as :wagbot  do
        card=Card[name] and !card.content.strip.empty? and card.content
      end
    end           

    def path_setting name
      name ||= '/'
      return name if name =~ /^(http|mailto)/
      Wagn::Conf[:root_path] + name      
    end
    
    def toggle(val) val == '1' end
  end

  
  # these old_modules should be refactored out
  require_dependency 'flexmail.rb'
  require_dependency 'google_maps_addon.rb'
  require_dependency 'notification.rb'
end  

