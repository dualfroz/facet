module Facet
  module Orm
    module Pagination
      DefaultPerPage = 25

      def page(number)
        paginate(page: number, per_page: @per_page_value || DefaultPerPage)
      end

      def per(size)
        paginate(page: @page_value || 1, per_page: size)
      end

      def current_page
        @page_value || 1
      end

      def per_page
        @per_page_value || DefaultPerPage
      end

      def total_count
        @total_count ||= unpaginated.count
      end

      def total_pages
        return 0 if total_count.zero?
        (total_count.to_f / per_page).ceil
      end

      def out_of_range?
        total_pages.positive? && current_page > total_pages
      end

      def first_page?
        current_page <= 1
      end

      def last_page?
        current_page >= total_pages
      end

      def prev_page
        first_page? ? nil : current_page - 1
      end

      def next_page
        last_page? ? nil : current_page + 1
      end

      private

      def paginate(page:, per_page:)
        page = [page.to_i, 1].max
        per_page = [per_page.to_i, 1].max
        spawn(page_value: page, per_page_value: per_page, limit_value: per_page, offset_value: (page - 1) * per_page)
      end

      def unpaginated
        spawn(page_value: nil, per_page_value: nil, limit_value: nil, offset_value: nil)
      end
    end
  end
end
