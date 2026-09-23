class LoginSession < Facet::Orm::Model
  belongs_to :user

  has_secure_token :token
  hide_from_json :token
end
