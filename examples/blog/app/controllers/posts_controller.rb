class PostsController < Prism::Controller
  layout :application

  def index
    render(:index, locals: { posts: Post.order(:created_at, :desc), notice: flash[:notice], errors: [] })
  end

  def show
    render(:show, locals: { post: Post.find(params['id']) })
  rescue Prism::Orm::RecordNotFound
    halt(404, 'Post not found')
  end

  def create
    post = Post.new(title: params['title'], body: params['body'])
    if post.save
      flash[:notice] = "Post ##{post.id} created"
      redirect url_for(:posts)
    else
      status(422)
      render(:index, locals: { posts: Post.order(:created_at, :desc), notice: nil, errors: post.errors.full_messages })
    end
  end
end
