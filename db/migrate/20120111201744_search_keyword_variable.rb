class SearchKeywordVariable < ActiveRecord::Migration
  def up
    User.as :wagbot do
      c = Card.fetch_or_new '*search'
      c = c.refresh if c.frozen?
      c.typecode = 'Search'
      c.content = c.content.sub '"_keyword"', '"$keyword"'
      c.save!
    end
  end

  def down
    User.as :wagbot do
      c = Card.fetch_or_new '*search'
      c = c.refresh if c.frozen?
      c.typecode = 'Search'
      c.content = c.content.sub '"$keyword"', '"_keyword"'
      c.save!
    end
  end
end
