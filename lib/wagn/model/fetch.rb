# = Card#fetch
#
# A multipurpose retrieval operator that incorporates caching, "virtual" card retrieval


module Wagn::Model::Fetch
  mattr_accessor :cache

  module ClassMethods

    # === fetch
    #
    # looks for cards in
    #   - cache
    #   - database
    #   - virtual cards

    def fetch cardname, opts = {}
#      ActiveSupport::Notifications.instrument 'wagn.fetch', :message=>"fetch #{cardname}" do
      
        cardname = cardname.to_cardname
        opts[:skip_virtual] = true if opts[:loaded_trunk]

        card = Card.cache.read( cardname.key ) if Card.cache
        return nil if card && opts[:skip_virtual] && card.new_card?

        needs_caching = card.nil?
        card ||= find_by_key_and_trash cardname.key, false
    
        if card.nil? or !opts[:skip_virtual] && card.typecode=='$NoType'
          # The $NoType typecode allows us to skip all the type lookup and flag the need for reinitialization later
          needs_caching = true
          card = new :name=>cardname, :skip_modules=>true, :typecode=>( opts[:skip_virtual] ? '$NoType' : '' )
        end
    
        Card.cache.write( cardname.key, card ) if Card.cache && needs_caching
      
        return nil if card.new_card? and opts[:skip_virtual] || !card.virtual?

        card.include_set_modules unless opts[:skip_modules]
        card
#      end
    end

    def fetch_or_new cardname, opts={}      
      fetch( cardname, opts ) || new( opts.merge(:name=>cardname) )
    end
    
    def fetch_or_create cardname, opts={}
      opts[:skip_virtual] ||= true
      fetch( cardname, opts ) || create( opts.merge(:name=>cardname) )
    end

    def exists?(cardname)
      fetch(cardname, :skip_virtual=>true, :skip_modules=>true).present?
    end
    
    def autoname(name)
      exists?(name) ? autoname(name.next) : name
    end
  end

  def refresh
    fresh_card = self.class.find(self.id)
    fresh_card.include_set_modules
    fresh_card
  end

  def self.included(base)
    super
    base.extend Wagn::Model::Fetch::ClassMethods
  end
end



