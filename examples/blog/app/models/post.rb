class Post < Prism::Orm::Model
  validates :title, presence: true, length: { minimum: 3 }
end
