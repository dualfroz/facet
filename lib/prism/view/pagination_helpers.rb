module Prism
  # Renders page links for an `Orm::Relation` that has been through
  # `.page(n)`. Deliberately decoupled from the router/request: the caller
  # supplies `path` (a Proc mapping a page number to a URL string), so the
  # helper works for `/posts?page=n`, `/blog/:id/comments?page=n`, or
  # anything else without knowing about routes itself.
  module PaginationHelpers
    def paginate(relation, path:, window: 2)
      return '' if relation.total_pages <= 1

      links = +''
      links << pagination_nav_link('Previous', relation.prev_page, path)
      pagination_page_numbers(relation, window).each do |page|
        links << if page == :gap
                   content_tag(:span, '...', class: 'page-gap')
                 else
                   pagination_page_link(page, relation.current_page, path)
                 end
      end
      links << pagination_nav_link('Next', relation.next_page, path)
      "#{tag(:nav, class: 'pagination')}#{links}</nav>"
    end

    private

    def pagination_page_numbers(relation, window)
      total = relation.total_pages
      current = relation.current_page
      visible = (1..total).select { |page| page == 1 || page == total || (page - current).abs <= window }

      visible.each_with_object([]) do |page, result|
        result << :gap if result.any? && result.last != :gap && page - result.last != 1
        result << page
      end
    end

    def pagination_page_link(page, current_page, path)
      classes = page == current_page ? 'page-link current' : 'page-link'
      content_tag(:a, page.to_s, href: path.call(page), class: classes)
    end

    def pagination_nav_link(text, target_page, path)
      return content_tag(:span, text, class: 'page-link disabled') unless target_page
      content_tag(:a, text, href: path.call(target_page), class: 'page-link')
    end
  end
end
