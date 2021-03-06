require 'rexml/document'

module Svg
  begin
    require 'html5/sanitizer'
    SVG_ATTRIBUTES = HTML5::HTMLSanitizeModule::SVG_ATTRIBUTES
  rescue LoadError
    SVG_ATTRIBUTES = []
  end

  def self.tidy svg, opts

    # rescale the view
    if opts[:size]
      view = svg.root.attributes['viewBox']
      if !view and svg.root.attributes['height']
        view = "0 0 #{svg.root.attributes['width']} " +
          svg.root.attributes['height']
      end
      if view
        view = view.scan(/[-0-9.]+/).map {|n| n.to_f}
        transform = ''
      
        scale = opts[:size] / Math.sqrt(view[2]*view[3])
        transform += " scale(#{scale})" if scale != 1.0
      
        if !view[0].zero? or !view[1].zero?
          transform += " translate(#{-view[0]},#{-view[1]})"
        end
      
        svg.root.attributes['transform'] = transform unless transform.empty?
        svg.root.attributes['viewBox'] = "0 0 " + 
          "#{(view[2]*scale).round} #{(view[3]*scale).round}"

        svg.root.delete_attribute('height')
        svg.root.delete_attribute('width')
      end
    end
    
    # convert polygons to paths
    svg.elements.each('//polygon') do |poly|
      points = poly.attributes['points']
      points = points.scan(/[-0-9.]+/).map {|n| n.to_f}
      points = (0..points.length/2-1).map {|i| points[i*2,2].join(',')}
      poly.attributes['d'] = "M#{points.join('L')}z"
      poly.attributes.delete('points')
      poly.name = 'path'
    end
    
    # process each rect
    svg.elements.each('//rect') do |rect|
      origin = [rect.attributes['x'].to_f, rect.attributes['y'].to_f]
      size   = [rect.attributes['width'].to_f, rect.attributes['height'].to_f]
      rect.elements.to_a('ancestor-or-self::*[@transform]').each do |node|
         origin = node.apply_transform(origin)
         size   = node.apply_transform(size)
      end
      origin.map! {|n| n.round} if opts[:grid]
      size.map!   {|n| n.round} if opts[:grid]

      rect.attributes['x'] = origin.first
      rect.attributes['y'] = origin.last
      rect.attributes['width'] = size.first
      rect.attributes['height'] = size.last
    end

    # process each path
    svg.elements.each('//path[@d]') do |path|
      d = path.attributes['d']
    
      # convert to absolute coordinates
      pen=[0,0]
      origin=[0,0]
      d = d.scan(/([a-zA-Z])([-0-9., ]*)/).map { |action,coords|
        coords = coords.scan(/-?[0-9.]+/).map {|n| n.to_f}
    
        action,coords='l',[coords[0],0] if action=='h'
        action,coords='l',[0,coords[0]] if action=='v'
        action,coords='L',[coords[0],pen[1]] if action=='H'
        action,coords='L',[pen[0],coords[0]] if action=='V'

        if action =~ /[clm]/
          coords.length.times { |i| coords[i] += pen[i%2] }
          action.upcase!
        end
        pen=coords[-2,2] unless coords.empty?
        origin = pen if action == 'M'
        pen = origin if action.upcase == 'Z'
        "#{action}#{coords.join(',')}"
      }.join('').gsub(',-','-')
    
      # apply all transforms
      path.elements.to_a('ancestor-or-self::*[@transform]').each do |node|
        d = d.scan(/([a-zA-Z])([-0-9., ]*)/).map { |action,coords|
          coords = coords.scan(/-?[0-9.]+/).map {|n| n.to_f}
    
          if action == 'A'
            coords[0,2] = node.apply_transform(coords[0,2])
            coords[5,2] = node.apply_transform(coords[5,2])
          elsif coords.length > 0
            coords = * (0...coords.length).to_a.select {|i| i%2==0}.
              map{|i| node.apply_transform(coords[i,2])}.flatten
          end
    
          "#{action}#{coords.join(',')}"
        }.join(' ')
      end
    
      # convert to relative coordinates and integerize
      pen=[0,0]
      origin=[0,0]
      d = d.scan(/([a-zA-Z])([-0-9., e]*)/).map { |action,coords|
        coords = coords.scan(/-?[0-9.]+(?:e[-+]\d+)?/).map {|n| n.to_f}
        coords.map! {|n| n.round} if opts[:grid]
        dest=coords[-2,2]
    
        if action == 'M'
          origin = coords
        elsif action == 'L' and coords == origin
          action,coords = 'z',[]
        elsif !opts[:absolute]
          if action == 'A'
            [5,6].each { |i| coords[i] -= pen[i%5] }
          else
            coords.length.times { |i| coords[i] -= pen[i%2] }
          end
          action.downcase!
        end
    
        # collapse straight curves
        if action == 'c'
          d3 = Math.sqrt(coords[4]**2 + coords[5]**2)
          d3 = 1.0 if d3.zero?
          d1 = Math.sqrt(coords[0]**2 + coords[1]**2)/d3
          d2 = Math.sqrt(coords[2]**2 + coords[3]**2)/d3
          if coords[0] == (d1*coords[4]).round and
             coords[1] == (d1*coords[5]).round and
             coords[2] == (d2*coords[4]).round and
             coords[3] == (d2*coords[5]).round
            action,coords = 'l',[coords[4],coords[5]]
          end
        end

        if action == 'l'
          next if coords == [0,0]
          action,coords='v',coords[1,1] if coords[0]==0
          action,coords='h',coords[0,1] if coords[1]==0
        end
    
        if action == 'z'
          next if pen == origin
          pen=origin
        else
          pen=dest if dest
        end

        "#{action}#{coords.map{|n| n.to_s.sub('.0','')}.join(',')}"
      }.join('').gsub(',-','-')
    
      path.attributes['d'] = d
    end
    
    # convert style to attributes
    svg.elements.each('//*[@style]') do |node|
      style = node.attributes['style']

      # don't bother if incomprehensible
      next unless style =~ /^([:,;#%.\sa-zA-Z0-9!]|\w-\w|\'[\s\w]+\'|\"[\s\w]+\"|\([\d,\s]+\))*$/
      next unless style =~ /^(\s*[-\w]+\s*:\s*[^:;]*(;|$))*$/

      style.gsub!(/([-\w]+)\s*:\s*([^:;]*)/) do
        prop, value = $1, $2
        if SVG_ATTRIBUTES.include? prop
          node.attributes[prop] = value
          ""
        else
          "#{prop}:#{value}"
        end
      end

      style = style.gsub(/^;+/,'').gsub(/;+$/,'').gsub(/;+/,';')
      if style == ''
        node.attributes.delete('style')
      else
        node.attributes['style'] = style
      end
    end

    # redundancy elimination
    %w(fill-opacity opacity stop-opacity stroke-opacity).each do |word|
      svg.elements.each("//*[@#{word}=1]") do |node|
        node.attributes.delete(word)
      end
    end

    # redundancy elimination
    svg.elements.each("//*[@stroke='none']") do |node|
      node.attributes.each do |name, value|
        node.attributes.delete(name) if name =~ /^stroke-/
      end
    end

    # remove inkscape extensions
    if opts[:strip_inkscape]
      inkscape_namespaces = %w(
        http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd
        http://www.inkscape.org/namespaces/inkscape
      )

      svg.elements.each('//*') do |node|
        if inkscape_namespaces.include? node.namespace
          node.remove
        else
          node.attributes.to_a.each do |attr|
            if attr.respond_to? :values
              attr.values.each do |a|
                if inkscape_namespaces.include? a.namespace
                  node.attributes.delete a
                end
              end
            elsif inkscape_namespaces.include? attr.namespace
              node.attributes.delete attr
            end
          end
        end
      end
      svg.root.delete_namespace 'inkscape'
      svg.root.delete_namespace 'sodipodi'
    end

    # remove transform attributes as they already have been applied
    svg.elements.to_a('//*[@transform]').each do |node|
      node.attributes.delete('transform')
    end

    svg
  end

  class REXML::Element
    def apply_transform(point)
      x,y = point
  
      attributes['transform'].scan(/\w+\(.*?\)/).reverse.each do |transform|
        case transform
        when /matrix\(.*\)/
          matrix = transform.scan(/[\d.-]+/).map {|n| n.to_f}
          x,y = x*matrix[0]+y*matrix[2]+matrix[4],
                x*matrix[1]+y*matrix[3]+matrix[5]
        when /translate\(.*\)/
          translate = transform.scan(/[\d.-]+/).map {|n| n.to_f}
          x,y = [x+translate[0],y+translate[1]]
        when /scale\(.*\)/
          scale = transform.scan(/[\d.-]+/).map {|n| n.to_f}
          x,y = [x*scale.first, y*scale.last]
        when /rotate\(.*\)/
          angle = transform.scan(/[\d.-]+/).map {|n| n.to_f}.first/180*Math::PI
          x,y = x * Math.cos(angle) - y * Math.sin(angle),
                x * Math.sin(angle) + y * Math.cos(angle)
        end
      end
  
      [x,y]
    end
  end
end    

if $0 == __FILE__
  # parse options
  require 'optparse'
  opts = {}
  OptionParser.new {|opt|
    opt.on "--size LENGTH", "resize to approximately LENGTH x LENGTH, " +
      "preserving the aspect ratio" do |length|
      opts[:size] = length.to_f 
    end

    opt.on "--grid", "snap points to grid coordinates" do
      opts[:grid] = true
    end

    opt.on "--absolute", "use absolute coordinates" do
      opts[:absolute] = true
    end

    opt.on "--strip-inkscape",
      "remove inkscape and sodipodi elements and attributes" do
      opts[:strip_inkscape] = true
    end
  }.parse! ARGV

  STDOUT.write Svg.tidy(REXML::Document.new(STDIN.read), opts).to_s
end
